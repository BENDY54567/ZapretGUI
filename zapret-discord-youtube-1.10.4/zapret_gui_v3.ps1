[System.Reflection.Assembly]::LoadWithPartialName("PresentationFramework") | Out-Null
[System.Reflection.Assembly]::LoadWithPartialName("PresentationCore") | Out-Null
[System.Reflection.Assembly]::LoadWithPartialName("WindowsBase") | Out-Null
[System.Reflection.Assembly]::LoadWithPartialName("System.Windows.Forms") | Out-Null
[System.Reflection.Assembly]::LoadWithPartialName("System.Drawing") | Out-Null

# ---------------------------------------------------------------
# Реальный захват системного звука через WASAPI (loopback) — без
# сторонних библиотек, компилируется на лету встроенным в Windows
# компилятором C#. Если по какой-то причине не соберётся или не
# запустится на конкретной системе — приложение просто продолжит
# работать без реальной аудио-реакции (используется try/catch).
# ---------------------------------------------------------------
$script:BassMeterAvailable = $false
$script:BassMeterCompileError = ""
try {
    if (([System.Management.Automation.PSTypeName]'ZapretAudio.BassMeter').Type) {
        # тип уже загружен в этот процесс (повторный запуск скрипта в той же сессии)
        $script:BassMeterAvailable = $true
    } else {
        $bassMeterSource = @'
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;

namespace ZapretAudio
{
    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
    class MMDeviceEnumeratorComObject { }

    [Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceEnumerator
    {
        [PreserveSig] int EnumAudioEndpoints(int dataFlow, int stateMask, out IntPtr devices);
        [PreserveSig] int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice device);
        [PreserveSig] int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string id, out IMMDevice device);
        [PreserveSig] int RegisterEndpointNotificationCallback(IntPtr client);
        [PreserveSig] int UnregisterEndpointNotificationCallback(IntPtr client);
    }

    [Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDevice
    {
        [PreserveSig] int Activate(ref Guid iid, int dwClsCtx, IntPtr pActivationParams, [MarshalAs(UnmanagedType.IUnknown)] out object ppInterface);
        [PreserveSig] int OpenPropertyStore(int stgmAccess, out IntPtr properties);
        [PreserveSig] int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
        [PreserveSig] int GetState(out int state);
    }

    [Guid("1CB9AD4C-DBFA-4c32-B178-C2F568A703B2"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioClient
    {
        [PreserveSig] int Initialize(int shareMode, int streamFlags, long hnsBufferDuration, long hnsPeriodicity, IntPtr pFormat, IntPtr audioSessionGuid);
        [PreserveSig] int GetBufferSize(out uint bufferFrameCount);
        [PreserveSig] int GetStreamLatency(out long latency);
        [PreserveSig] int GetCurrentPadding(out uint padding);
        [PreserveSig] int IsFormatSupported(int shareMode, IntPtr pFormat, out IntPtr closestMatch);
        [PreserveSig] int GetMixFormat(out IntPtr deviceFormat);
        [PreserveSig] int GetDevicePeriod(out long defaultDevicePeriod, out long minimumDevicePeriod);
        [PreserveSig] int Start();
        [PreserveSig] int Stop();
        [PreserveSig] int Reset();
        [PreserveSig] int SetEventHandle(IntPtr eventHandle);
        [PreserveSig] int GetService(ref Guid riid, [MarshalAs(UnmanagedType.IUnknown)] out object ppv);
    }

    [Guid("C8ADBD64-E71E-48a0-A4DE-185C395CD317"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioCaptureClient
    {
        [PreserveSig] int GetBuffer(out IntPtr dataBuffer, out uint numFramesToRead, out uint flags, out ulong devicePosition, out ulong qpcPosition);
        [PreserveSig] int ReleaseBuffer(uint numFramesRead);
        [PreserveSig] int GetNextPacketSize(out uint numFramesInNextPacket);
    }

    // Разбор звука: декодирование любого формата микшера -> моно -> НЧ-фильтр (бас) -> огибающая.
    class Analyzer
    {
        private readonly int _ch;
        private readonly int _bits;
        private readonly bool _float;

        private float[] _fbuf = new float[0];
        private short[] _sbuf = new short[0];
        private int[] _ibuf = new int[0];
        private byte[] _bbuf = new byte[0];

        // Два каскада биквадного НЧ-фильтра Баттерворта (итого 4-й порядок, ~24 дБ/окт), срез ~140 Гц
        private readonly double _b0, _b1, _b2, _a1, _a2;
        private double _z1a, _z2a, _z1b, _z2b;

        // Следящая огибающая: быстрая атака, плавный спад
        private readonly double _atk, _rel;
        private double _env;
        private double _blockMax;

        // Огибающая всего сигнала (без фильтра) — нужна, чтобы отличать настоящий бас от "крох" низких частот
        private double _envF;
        private double _blockMaxF;

        public Analyzer(int sampleRate, int channels, int bits, bool isFloat)
        {
            _ch = channels;
            _bits = bits;
            _float = isFloat;

            double fs = sampleRate;
            double fc = 140.0;
            double q = 0.70710678;
            double w0 = 2.0 * Math.PI * fc / fs;
            double cosw = Math.Cos(w0);
            double alpha = Math.Sin(w0) / (2.0 * q);
            double a0 = 1.0 + alpha;
            _b0 = ((1.0 - cosw) / 2.0) / a0;
            _b1 = (1.0 - cosw) / a0;
            _b2 = _b0;
            _a1 = (-2.0 * cosw) / a0;
            _a2 = (1.0 - alpha) / a0;

            _atk = 1.0 - Math.Exp(-1.0 / (fs * 0.004));
            _rel = 1.0 - Math.Exp(-1.0 / (fs * 0.090));
        }

        private void Step(float x)
        {
            double y = x;
            double o1 = _b0 * y + _z1a;
            _z1a = _b1 * y - _a1 * o1 + _z2a;
            _z2a = _b2 * y - _a2 * o1;
            double o2 = _b0 * o1 + _z1b;
            _z1b = _b1 * o1 - _a1 * o2 + _z2b;
            _z2b = _b2 * o1 - _a2 * o2;

            double a = o2 < 0 ? -o2 : o2;
            if (a > _env) _env += (a - _env) * _atk;
            else _env += (a - _env) * _rel;
            if (_env > _blockMax) _blockMax = _env;

            double af = y < 0 ? -y : y;
            if (af > _envF) _envF += (af - _envF) * _atk;
            else _envF += (af - _envF) * _rel;
            if (_envF > _blockMaxF) _blockMaxF = _envF;
        }

        public void FeedSilence(int frames)
        {
            if (frames > 20000) frames = 20000;
            for (int i = 0; i < frames; i++) Step(0f);
            // не даём числам уйти в денормализованную область
            if (_env < 1e-12) _env = 0;
            if (_envF < 1e-12) _envF = 0;
            if (Math.Abs(_z1a) < 1e-15) _z1a = 0;
            if (Math.Abs(_z2a) < 1e-15) _z2a = 0;
            if (Math.Abs(_z1b) < 1e-15) _z1b = 0;
            if (Math.Abs(_z2b) < 1e-15) _z2b = 0;
        }

        // Возвращает true, если формат поддержан и данные обработаны
        public bool Feed(IntPtr data, int frames)
        {
            int total = frames * _ch;
            if (total <= 0) return true;

            if (_float && _bits == 32)
            {
                if (_fbuf.Length < total) _fbuf = new float[total];
                Marshal.Copy(data, _fbuf, 0, total);
                for (int i = 0; i < frames; i++)
                {
                    float s = 0f;
                    int b = i * _ch;
                    for (int c = 0; c < _ch; c++) s += _fbuf[b + c];
                    Step(s / _ch);
                }
                return true;
            }
            if (!_float && _bits == 16)
            {
                if (_sbuf.Length < total) _sbuf = new short[total];
                Marshal.Copy(data, _sbuf, 0, total);
                for (int i = 0; i < frames; i++)
                {
                    float s = 0f;
                    int b = i * _ch;
                    for (int c = 0; c < _ch; c++) s += _sbuf[b + c];
                    Step((s / _ch) / 32768f);
                }
                return true;
            }
            if (!_float && _bits == 32)
            {
                if (_ibuf.Length < total) _ibuf = new int[total];
                Marshal.Copy(data, _ibuf, 0, total);
                for (int i = 0; i < frames; i++)
                {
                    float s = 0f;
                    int b = i * _ch;
                    for (int c = 0; c < _ch; c++) s += _ibuf[b + c] / 2147483648f;
                    Step(s / _ch);
                }
                return true;
            }
            if (!_float && _bits == 24)
            {
                int bytes = total * 3;
                if (_bbuf.Length < bytes) _bbuf = new byte[bytes];
                Marshal.Copy(data, _bbuf, 0, bytes);
                for (int i = 0; i < frames; i++)
                {
                    float s = 0f;
                    int b = i * _ch;
                    for (int c = 0; c < _ch; c++)
                    {
                        int o = (b + c) * 3;
                        int v = (_bbuf[o] << 8) | (_bbuf[o + 1] << 16) | (_bbuf[o + 2] << 24);
                        s += v / 2147483648f;
                    }
                    Step(s / _ch);
                }
                return true;
            }
            return false;
        }

        // Максимум огибающей баса с прошлого вызова (так не теряются короткие удары бочки)
        public double TakeBlockMax()
        {
            double m = _blockMax;
            _blockMax = _env;
            return m;
        }

        // То же для огибающей всего сигнала
        public double TakeFullMax()
        {
            double m = _blockMaxF;
            _blockMaxF = _envF;
            return m;
        }
    }

    public class BassMeter
    {
        private readonly object _lock = new object();
        private Thread _thread;
        private volatile bool _run;
        private volatile int _gen;
        private volatile float _level;
        private volatile bool _capturing;
        private volatile string _lastError = "";
        private volatile string _info = "";
        private long _packets;

        // Уровень баса 0..1 (уже нормирован по громкости и сглажен)
        public float BassLevel { get { return _level; } }
        // true, когда захват системного звука реально идёт
        public bool IsCapturing { get { return _capturing; } }
        public string LastError { get { return _lastError; } }
        public string Info { get { return _info; } }
        public long PacketCount { get { return Interlocked.Read(ref _packets); } }

        // Безопасно вызывать сколько угодно раз: второй поток не создаётся
        public bool Start()
        {
            lock (_lock)
            {
                if (_run && _thread != null && _thread.IsAlive) return true;
                _gen++;
                int myGen = _gen;
                _run = true;
                _level = 0f;
                _lastError = "";
                _thread = new Thread(delegate() { Run(myGen); });
                _thread.IsBackground = true;
                _thread.Name = "ZapretBassMeter";
                _thread.SetApartmentState(ApartmentState.MTA);
                _thread.Start();
                return true;
            }
        }

        public void Stop()
        {
            Thread t;
            lock (_lock)
            {
                _run = false;
                _gen++;
                t = _thread;
            }
            _level = 0f;
            _capturing = false;
            if (t != null)
            {
                try { t.Join(300); } catch { }
            }
        }

        private bool Alive(int gen)
        {
            return _run && gen == _gen;
        }

        private static void Check(int hr, string what)
        {
            if (hr < 0)
                throw new InvalidOperationException(what + " (HRESULT 0x" + hr.ToString("X8") + ")");
        }

        private static void ReleaseCom(object o)
        {
            try
            {
                if (o != null && Marshal.IsComObject(o)) Marshal.ReleaseComObject(o);
            }
            catch { }
        }

        // Внешний цикл: любой сбой (смена устройства вывода, отключение наушников и т.п.)
        // не убивает анализатор — сессия пересоздаётся.
        private void Run(int gen)
        {
            int backoff = 250;
            while (Alive(gen))
            {
                try
                {
                    Session(gen);
                    backoff = 250;
                }
                catch (Exception ex)
                {
                    _lastError = ex.Message;
                    if (backoff < 2000) backoff *= 2;
                }
                _capturing = false;
                _level = 0f;
                int waited = 0;
                while (waited < backoff && Alive(gen))
                {
                    Thread.Sleep(50);
                    waited += 50;
                }
            }
            _capturing = false;
        }

        private void Session(int gen)
        {
            object enumObj = null;
            IMMDeviceEnumerator enumerator = null;
            IMMDevice device = null;
            IAudioClient client = null;
            IAudioCaptureClient capture = null;
            IntPtr mixFormat = IntPtr.Zero;

            try
            {
                enumObj = new MMDeviceEnumeratorComObject();
                enumerator = (IMMDeviceEnumerator)enumObj;

                // eRender (0), eConsole (0): устройство вывода по умолчанию
                Check(enumerator.GetDefaultAudioEndpoint(0, 0, out device), "GetDefaultAudioEndpoint");
                string deviceId;
                Check(device.GetId(out deviceId), "GetId");

                Guid iidClient = new Guid("1CB9AD4C-DBFA-4c32-B178-C2F568A703B2");
                object clientObj;
                // 23 = CLSCTX_ALL
                Check(device.Activate(ref iidClient, 23, IntPtr.Zero, out clientObj), "Activate(IAudioClient)");
                client = (IAudioClient)clientObj;

                Check(client.GetMixFormat(out mixFormat), "GetMixFormat");
                int tag = Marshal.ReadInt16(mixFormat, 0) & 0xFFFF;
                int channels = Marshal.ReadInt16(mixFormat, 2) & 0xFFFF;
                int sampleRate = Marshal.ReadInt32(mixFormat, 4);
                int bits = Marshal.ReadInt16(mixFormat, 14) & 0xFFFF;
                int cbSize = Marshal.ReadInt16(mixFormat, 16) & 0xFFFF;

                bool isFloat = (tag == 3);
                bool known = (tag == 1 || tag == 3);
                if (tag == 0xFFFE && cbSize >= 22)
                {
                    // WAVE_FORMAT_EXTENSIBLE: тип данных лежит в первых 4 байтах SubFormat (смещение 24)
                    int sub = Marshal.ReadInt32(mixFormat, 24);
                    isFloat = (sub == 3);
                    known = (sub == 1 || sub == 3);
                }
                if (!known || channels < 1 || sampleRate < 8000)
                    throw new InvalidOperationException("Неподдерживаемый формат микшера (tag=" + tag + ", " + channels + " кан., " + sampleRate + " Гц)");

                // 0 = AUDCLNT_SHAREMODE_SHARED, 0x00020000 = AUDCLNT_STREAMFLAGS_LOOPBACK, буфер 100 мс
                Check(client.Initialize(0, 0x00020000, 1000000L, 0L, mixFormat, IntPtr.Zero), "Initialize(loopback)");

                Guid iidCapture = new Guid("C8ADBD64-E71E-48a0-A4DE-185C395CD317");
                object capObj;
                Check(client.GetService(ref iidCapture, out capObj), "GetService(IAudioCaptureClient)");
                capture = (IAudioCaptureClient)capObj;

                Analyzer analyzer = new Analyzer(sampleRate, channels, bits, isFloat);
                Check(client.Start(), "Start");

                _info = sampleRate + " Гц, " + channels + " кан., " + bits + "-бит " + (isFloat ? "float" : "int");
                _capturing = true;
                _lastError = "";

                Stopwatch sw = Stopwatch.StartNew();
                long lastTick = 0;
                long lastDataMs = 0;
                long lastDevCheck = 0;
                double peak = 0.0;
                double fullPeak = 0.0;
                double slow = 0.0;
                double outv = 0.0;

                while (Alive(gen))
                {
                    long now = sw.ElapsedMilliseconds;
                    double dt = (now - lastTick) / 1000.0;
                    lastTick = now;
                    if (dt < 0.001) dt = 0.001;
                    if (dt > 0.25) dt = 0.25;

                    int framesThisTick = 0;
                    uint packet;
                    Check(capture.GetNextPacketSize(out packet), "GetNextPacketSize");
                    int guard = 0;
                    while (packet != 0 && guard < 64 && Alive(gen))
                    {
                        guard++;
                        IntPtr data;
                        uint frames;
                        uint flags;
                        ulong devPos;
                        ulong qpcPos;
                        int hr = capture.GetBuffer(out data, out frames, out flags, out devPos, out qpcPos);
                        Check(hr, "GetBuffer");
                        if (hr != 0) break; // AUDCLNT_S_BUFFER_EMPTY: данных нет, буфер освобождать не нужно

                        int n = (int)frames;
                        if (n > 0)
                        {
                            // 0x2 = AUDCLNT_BUFFERFLAGS_SILENT: содержимому буфера верить нельзя, это тишина
                            if ((flags & 2u) != 0 || data == IntPtr.Zero) analyzer.FeedSilence(n);
                            else if (!analyzer.Feed(data, n))
                                throw new InvalidOperationException("Неподдерживаемая разрядность звука: " + bits + " бит");
                            framesThisTick += n;
                            Interlocked.Increment(ref _packets);
                        }
                        Check(capture.ReleaseBuffer(frames), "ReleaseBuffer");
                        Check(capture.GetNextPacketSize(out packet), "GetNextPacketSize");
                    }

                    if (framesThisTick > 0)
                    {
                        lastDataMs = now;
                    }
                    else if (now - lastDataMs > 80)
                    {
                        // На многих устройствах loopback при тишине вообще не отдаёт пакеты.
                        // После короткой паузы считаем это тишиной, иначе уровень "залипал" бы на последнем значении.
                        analyzer.FeedSilence((int)(dt * sampleRate));
                    }

                    double blockEnv = analyzer.TakeBlockMax();
                    double fullEnv = analyzer.TakeFullMax();

                    // АРУ: пик медленно "забывается" (полупериод ~4 с), снизу ограничен порогом шума.
                    // Благодаря этому эффект одинаково работает на тихой и громкой музыке.
                    double decay = Math.Pow(0.5, dt / 4.0);
                    peak *= decay;
                    fullPeak *= decay;
                    if (blockEnv > peak) peak = blockEnv;
                    if (fullEnv > fullPeak) fullPeak = fullEnv;

                    // Контроль доминирования баса: опорный уровень не может быть меньше 12% общей громкости.
                    // Без этого АРУ раздувала бы до полной шкалы любые крохи низких частот
                    // (например, у голоса или трека без баса) и свечение мигало бы "ни о чём".
                    double refLevel = peak;
                    double gate = 0.12 * fullPeak;
                    if (gate > refLevel) refLevel = gate;
                    if (refLevel < 0.004) refLevel = 0.004;
                    double norm = blockEnv / refLevel;
                    if (norm > 1.0) norm = 1.0;

                    // Акцент на ударах: насколько сейчас громче недавнего среднего
                    slow += (norm - slow) * (1.0 - Math.Exp(-dt / 0.5));
                    double punch = norm - slow * 0.85;
                    if (punch < 0) punch = 0;
                    double target = 0.45 * norm + 1.6 * punch;
                    if (target > 1.0) target = 1.0;

                    // Визуальное сглаживание: быстро вверх, плавно вниз
                    double tau = target > outv ? 0.02 : 0.09;
                    outv += (target - outv) * (1.0 - Math.Exp(-dt / tau));
                    if (outv < 0.001) outv = 0.0;
                    _level = (float)outv;

                    // Раз в секунду проверяем, не сменилось ли устройство вывода по умолчанию
                    if (now - lastDevCheck > 1000)
                    {
                        lastDevCheck = now;
                        IMMDevice cur;
                        if (enumerator.GetDefaultAudioEndpoint(0, 0, out cur) >= 0 && cur != null)
                        {
                            string curId;
                            int h2 = cur.GetId(out curId);
                            ReleaseCom(cur);
                            if (h2 >= 0 && curId != deviceId) return; // пересоздаём сессию на новом устройстве
                        }
                    }

                    Thread.Sleep(8);
                }
            }
            finally
            {
                _capturing = false;
                try { if (client != null) client.Stop(); } catch { }
                if (mixFormat != IntPtr.Zero)
                {
                    try { Marshal.FreeCoTaskMem(mixFormat); } catch { }
                }
                ReleaseCom(capture);
                ReleaseCom(client);
                ReleaseCom(device);
                ReleaseCom(enumerator);
                ReleaseCom(enumObj);
            }
        }
    }
}
'@
        Add-Type -TypeDefinition $bassMeterSource -Language CSharp -ErrorAction Stop
        $script:BassMeterAvailable = $true
    }
} catch {
    $script:BassMeterAvailable = $false
    $script:BassMeterCompileError = $_.Exception.Message
}

# ---------------------------------------------------------------
# Zapret GUI v3 — всё управление встроено в окно, без внешних консолей
# ---------------------------------------------------------------

function Get-SelfPath {
    if ($PSScriptRoot -and (Test-Path $PSScriptRoot)) {
        return $PSCommandPath
    }
    return [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
}

$SelfPath = Get-SelfPath
$ScriptDir = Split-Path -Parent $SelfPath

function Resolve-ZapretDir {
    param([string]$BaseDir)
    if (Test-Path (Join-Path $BaseDir "service.bat")) {
        return $BaseDir
    }
    $sub = Get-ChildItem -LiteralPath $BaseDir -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { Test-Path (Join-Path $_.FullName "service.bat") } |
        Select-Object -First 1
    if ($sub) { return $sub.FullName }
    return $BaseDir
}

$ZapretDir = Resolve-ZapretDir -BaseDir $ScriptDir
$UtilsDir  = Join-Path $ZapretDir "utils"
$ListsDir  = Join-Path $ZapretDir "lists"

# --- Автоповышение прав ---
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    if ($SelfPath -like "*.ps1") {
        Start-Process powershell -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$SelfPath`""
    } else {
        Start-Process -FilePath $SelfPath -Verb RunAs
    }
    exit
}

# ---------------------------------------------------------------
# Бета-доступ: общий ключ на время закрытого бета-тестирования
# ---------------------------------------------------------------
# Это "мягкая" защита: программа — открытый скрипт, и проверку можно вырезать, если уметь править файл.
# Ключ отсеивает случайных людей, но не защищает от того, кто захочет обойти. В самом скрипте хранится
# только хеш ключа (не сам ключ). Сменить ключ: Set-BetaKey.ps1 (файл только для автора).
$script:BetaKeySalt = '07eb9f2a13c45794'
$script:BetaKeyHash = '95d855193bfb215a55d3742c8a52aefd4dc0bcb2768c5dd6f9577eb78acba3ac'
$script:LicenseFile = Join-Path $UtilsDir "license.dat"

function Get-Sha256Hex {
    param([string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text)) } finally { $sha.Dispose() }
    return (($bytes | ForEach-Object { $_.ToString("x2") }) -join "")
}

function Get-MachineId {
    try {
        $g = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Cryptography" -Name MachineGuid -ErrorAction Stop).MachineGuid
        if ($g) { return [string]$g }
    } catch {}
    return [string]$env:COMPUTERNAME
}

# Метка активации привязана к ПК и к текущему ключу: файл с другого компьютера не подойдёт,
# а после смены ключа автору все активации сбрасываются сами.
function Get-LicenseToken {
    return (Get-Sha256Hex ($script:BetaKeyHash + ":" + (Get-MachineId)))
}

function Test-BetaActivated {
    try {
        if (Test-Path $script:LicenseFile) {
            $saved = (Get-Content -Path $script:LicenseFile -Raw -ErrorAction Stop).Trim()
            return ($saved -eq (Get-LicenseToken))
        }
    } catch {}
    return $false
}

function Test-BetaKey {
    param([string]$Key)
    $k = ([string]$Key).Trim().ToUpperInvariant()
    if (-not $k) { return $false }
    return ((Get-Sha256Hex ($script:BetaKeySalt + ":" + $k)) -eq $script:BetaKeyHash)
}

function Show-ActivationDialog {
    [xml]$actXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Zapret BETA — активация" Width="430" Height="320"
        WindowStartupLocation="CenterScreen" ResizeMode="NoResize" Topmost="True"
        Background="#0B0B12" FontFamily="Segoe UI">
    <StackPanel Margin="28,24">
        <TextBlock Text="Бета-доступ" Foreground="White" FontSize="20" FontWeight="Bold"/>
        <TextBlock Text="Введите ключ бета-тестирования, чтобы продолжить. Ключ нужно ввести один раз на этом компьютере." Foreground="#8A8A99" FontSize="12.5" TextWrapping="Wrap" Margin="0,6,0,16"/>
        <TextBox x:Name="txtActKey" Height="38" Background="#1B1B27" Foreground="White" CaretBrush="White" BorderThickness="0" Padding="10,9" FontSize="14"/>
        <TextBlock x:Name="txtActError" Foreground="#E63950" FontSize="12" Margin="0,8,0,0" MinHeight="18" TextWrapping="Wrap"/>
        <StackPanel Orientation="Horizontal" Margin="0,12,0,0">
            <Button x:Name="btnActOk" Content="Активировать" Width="180" Height="42" Foreground="White" BorderThickness="0" FontSize="14" IsDefault="True" Cursor="Hand">
                <Button.Background>
                    <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                        <GradientStop Color="#8E44E0" Offset="0"/>
                        <GradientStop Color="#E63950" Offset="1"/>
                    </LinearGradientBrush>
                </Button.Background>
            </Button>
            <Button x:Name="btnActExit" Content="Выход" Width="110" Height="42" Margin="10,0,0,0" Background="#1B1B27" Foreground="White" BorderThickness="0" FontSize="14" IsCancel="True" Cursor="Hand"/>
        </StackPanel>
        <TextBlock Text="Ключ выдаёт автор программы." Foreground="#5E5E6B" FontSize="11" Margin="0,14,0,0"/>
    </StackPanel>
</Window>
"@
    $actReader = New-Object System.Xml.XmlNodeReader $actXaml
    $actWin = [Windows.Markup.XamlReader]::Load($actReader)
    $txtActKey = $actWin.FindName("txtActKey")
    $txtActError = $actWin.FindName("txtActError")
    $btnActOk = $actWin.FindName("btnActOk")
    $btnActExit = $actWin.FindName("btnActExit")

    $script:ActivationResult = $false
    $btnActOk.Add_Click({
        if (Test-BetaKey -Key $txtActKey.Text) {
            try { [System.IO.File]::WriteAllText($script:LicenseFile, (Get-LicenseToken)) } catch {}
            $script:ActivationResult = $true
            $actWin.Close()
        } else {
            $txtActError.Text = "Неверный ключ. Проверьте символы и попробуйте ещё раз."
            $txtActKey.SelectAll()
            [void]$txtActKey.Focus()
        }
    })
    $btnActExit.Add_Click({ $actWin.Close() })
    $actWin.Add_ContentRendered({ [void]$txtActKey.Focus() })
    [void]$actWin.ShowDialog()
    return $script:ActivationResult
}

if (-not (Test-BetaActivated)) {
    if (-not (Show-ActivationDialog)) { exit }
}

# ---------------------------------------------------------------
# Стратегии
# ---------------------------------------------------------------
function Get-Strategies {
    Get-ChildItem -LiteralPath $ZapretDir -Filter "*.bat" -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notlike "service*" -and $_.Name -notlike "ZapretGUI*" -and $_.Name -notlike "Build-EXE*" } |
        Sort-Object { [Regex]::Replace($_.Name, '(\d+)', { $args[0].Value.PadLeft(8, '0') }) } |
        Select-Object -ExpandProperty Name
}

function Get-ZapretStatus {
    $winws = Get-Process -Name "winws" -ErrorAction SilentlyContinue
    $svc = Get-Service -Name "zapret" -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq 'Running') {
        return @{ Text = "СЛУЖБА · автозапуск включён"; On = $true }
    } elseif ($winws) {
        return @{ Text = "Активно (обычный процесс)"; On = $true }
    } else {
        return @{ Text = "Отключено"; On = $false }
    }
}

function Invoke-ScCommand {
    param([string]$Arguments, [int]$TimeoutMs = 4000)
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = "sc.exe"
        $psi.Arguments = $Arguments
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        if (-not $p.WaitForExit($TimeoutMs)) { try { $p.Kill() } catch {} }
    } catch {}
}

function Stop-Zapret {
    # ВАЖНО: не используем Stop-Service — если winws.exe/служба не отвечает
    # на сигнал остановки корректно (частый случай для служб-обёрток над
    # обычным консольным exe, см. ошибку Windows 1053), Stop-Service может
    # зависнуть НАВСЕГДА в ожидании ответа. Поэтому сначала жёстко убиваем
    # процесс, а со службой работаем через sc.exe с собственным таймаутом.
    Get-Process -Name "winws" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    $svc = Get-Service -Name "zapret" -ErrorAction SilentlyContinue
    if ($svc) {
        Invoke-ScCommand -Arguments "stop zapret"
        Invoke-ScCommand -Arguments "delete zapret"
    }
    $wd = Get-Service -Name "WinDivert" -ErrorAction SilentlyContinue
    if ($wd) {
        Invoke-ScCommand -Arguments "stop WinDivert"
        Invoke-ScCommand -Arguments "delete WinDivert"
    }
}

function Install-ZapretService {
    param([int]$Index)
    $tempOut = [System.IO.Path]::GetTempFileName()
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "cmd.exe"
    $psi.Arguments = "/c `"`"$ZapretDir\service.bat`" admin > `"$tempOut`" 2>&1`""
    $psi.WorkingDirectory = $ZapretDir
    $psi.RedirectStandardInput = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $proc = [System.Diagnostics.Process]::Start($psi)
    Start-Sleep -Milliseconds 800
    try { $proc.StandardInput.WriteLine("1") } catch {}
    Start-Sleep -Milliseconds 800
    try { $proc.StandardInput.WriteLine($Index) } catch {}
    Start-Sleep -Seconds 3
    try { $proc.StandardInput.WriteLine("0") } catch {}
    try { $proc.StandardInput.Close() } catch {}

    # Важно: сначала дожидаемся завершения процесса (с жёстким таймаутом
    # и принудительным убийством), и только потом читаем вывод из файла.
    # Чтение "трубы" ДО завершения процесса — классический риск дедлока,
    # если вывод не помещается в системный буфер.
    $exited = $proc.WaitForExit(15000)
    if (-not $exited) { try { $proc.Kill() } catch {} }

    Start-Sleep -Milliseconds 300
    $stdout = Get-Content -LiteralPath $tempOut -Raw -ErrorAction SilentlyContinue
    Remove-Item $tempOut -Force -ErrorAction SilentlyContinue

    Start-Sleep -Milliseconds 500
    $svc = Get-Service -Name "zapret" -ErrorAction SilentlyContinue
    if (-not $svc -or $svc.Status -ne 'Running') {
        return @{ Success = $false; Log = $stdout }
    }
    return @{ Success = $true; Log = $stdout }
}

# ---------------------------------------------------------------
# Прямые реализации пунктов расширенного меню (без внешней консоли)
# ---------------------------------------------------------------
function Get-LocalVersion {
    $line = Get-Content (Join-Path $ZapretDir "service.bat") -ErrorAction SilentlyContinue |
        Select-String 'set "LOCAL_VERSION=' | Select-Object -First 1
    if ($line) { return ($line.Line -replace '.*LOCAL_VERSION=([\d\.]+).*', '$1') }
    return "неизвестно"
}

$script:GameFlagFile = Join-Path $UtilsDir "game_filter.enabled"

function Get-GameFilterConfig {
    # Понимает и старый формат файла (одна строка: all/tcp/udp), и новый (mode=/tcp=/udp=)
    $cfg = [PSCustomObject]@{ Mode = "disabled"; TcpRange = "1024-65535"; UdpRange = "1024-65535" }
    if (-not (Test-Path $script:GameFlagFile)) { return $cfg }
    $rawLines = Get-Content $script:GameFlagFile -ErrorAction SilentlyContinue
    foreach ($line in $rawLines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $parts = $line -split '=', 2
        $key = $parts[0].Trim()
        $val = if ($parts.Count -gt 1) { $parts[1].Trim() } else { $null }
        switch -Regex ($key) {
            '^mode$' { if ($val) { $cfg.Mode = $val.ToLower() } }
            '^all$'  { $cfg.Mode = "all" }
            '^tcp$'  { if ($val) { $cfg.TcpRange = $val } else { $cfg.Mode = "tcp" } }
            '^udp$'  { if ($val) { $cfg.UdpRange = $val } else { $cfg.Mode = "udp" } }
        }
    }
    return $cfg
}

function Test-GameFilterRange {
    param([string]$Range)
    if ([string]::IsNullOrWhiteSpace($Range)) { return $false }
    foreach ($item in ($Range -split ',')) {
        $item = $item.Trim()
        if ($item -notmatch '^\d+(-\d+)?$') { return $false }
        $bounds = $item -split '-'
        $start = [int]$bounds[0]
        $end = if ($bounds.Count -gt 1) { [int]$bounds[1] } else { $start }
        if ($start -lt 1 -or $start -gt 65535 -or $end -lt 1 -or $end -gt 65535 -or $start -gt $end) { return $false }
    }
    return $true
}

function Save-GameFilterSettings {
    param([string]$Mode, [string]$TcpRange, [string]$UdpRange)
    if ($Mode -eq "disabled") {
        if (Test-Path $script:GameFlagFile) { Remove-Item $script:GameFlagFile -Force }
        return
    }
    if ([string]::IsNullOrWhiteSpace($TcpRange)) { $TcpRange = "1024-65535" }
    if ([string]::IsNullOrWhiteSpace($UdpRange)) { $UdpRange = "1024-65535" }
    Set-Content -Path $script:GameFlagFile -Value @("mode=$Mode", "tcp=$TcpRange", "udp=$UdpRange")
}

function Get-GameFilterStatus {
    $cfg = Get-GameFilterConfig
    switch ($cfg.Mode) {
        "all" { return "TCP и UDP (TCP: $($cfg.TcpRange), UDP: $($cfg.UdpRange))" }
        "tcp" { return "только TCP ($($cfg.TcpRange))" }
        "udp" { return "только UDP ($($cfg.UdpRange))" }
        default { return "disabled" }
    }
}

$script:IpsetFile = Join-Path $ListsDir "ipset-all.txt"
$script:IpsetBackup = "$script:IpsetFile.backup"
function Get-IpsetState {
    if (-not (Test-Path $script:IpsetFile)) { return "any" }
    $raw = Get-Content $script:IpsetFile -Raw -ErrorAction SilentlyContinue
    if ([string]::IsNullOrWhiteSpace($raw)) { return "any" }
    if ($raw -match '203\.0\.113\.113/32') { return "none" }
    return "loaded"
}
function Invoke-IpsetToggle {
    $state = Get-IpsetState
    if ($state -eq "loaded") {
        if (Test-Path $script:IpsetBackup) { Remove-Item $script:IpsetBackup -Force }
        Rename-Item $script:IpsetFile "ipset-all.txt.backup"
        Set-Content -Path $script:IpsetFile -Value "203.0.113.113/32"
        return @("Переключено в режим NONE (обход без списка адресов).")
    } elseif ($state -eq "none") {
        Set-Content -Path $script:IpsetFile -Value ""
        return @("Переключено в режим ANY (обход применяется ко всем адресам).")
    } else {
        if (Test-Path $script:IpsetBackup) {
            Remove-Item $script:IpsetFile -Force -ErrorAction SilentlyContinue
            Rename-Item $script:IpsetBackup "ipset-all.txt"
            return @("Переключено в режим LOADED (восстановлен список адресов).")
        } else {
            return @("Нет резервной копии списка. Сначала выполните 'Обновить список IP'.")
        }
    }
}

$script:CheckUpdatesFlag = Join-Path $UtilsDir "check_updates.enabled"
function Get-CheckUpdatesStatus { if (Test-Path $script:CheckUpdatesFlag) { "enabled" } else { "disabled" } }
function Invoke-ToggleCheckUpdates {
    if (Test-Path $script:CheckUpdatesFlag) { Remove-Item $script:CheckUpdatesFlag -Force; return "disabled" }
    New-Item -ItemType File -Path $script:CheckUpdatesFlag -Force | Out-Null
    return "enabled"
}

function Invoke-IpsetUpdate {
    $url = "https://raw.githubusercontent.com/Flowseal/zapret-discord-youtube/refs/heads/main/.service/ipset-service.txt"
    try {
        $res = Invoke-WebRequest -Uri $url -TimeoutSec 10 -UseBasicParsing
        if ($res.StatusCode -eq 200) {
            Set-Content -Path $script:IpsetFile -Value $res.Content -NoNewline
            return @("Список IP успешно обновлён.")
        }
        return @("Ошибка загрузки: HTTP $($res.StatusCode)")
    } catch {
        return @("Не удалось загрузить список IP: $($_.Exception.Message)")
    }
}

function Invoke-HostsUpdate {
    $hostsUrl = "https://raw.githubusercontent.com/Flowseal/zapret-discord-youtube/refs/heads/main/.service/hosts"
    $hostsFile = Join-Path $env:SystemRoot "System32\drivers\etc\hosts"
    $tempFile = Join-Path $env:TEMP "zapret_hosts.txt"
    try {
        $res = Invoke-WebRequest -Uri "$hostsUrl`?t=$(Get-Random)" -TimeoutSec 10 -UseBasicParsing
        if ($res.StatusCode -ne 200) { return @("Не удалось загрузить hosts-файл.") }
        Set-Content -Path $tempFile -Value $res.Content -NoNewline
    } catch {
        return @("Ошибка загрузки hosts: $($_.Exception.Message)")
    }
    $lines = Get-Content $tempFile -ErrorAction SilentlyContinue
    if (-not $lines -or $lines.Count -eq 0) { return @("Скачанный файл пуст.") }
    $first = $lines[0]
    $last = $lines[$lines.Count - 1]
    $current = Get-Content $hostsFile -ErrorAction SilentlyContinue
    $needsUpdate = $false
    if (-not ($current -match [regex]::Escape($first))) { $needsUpdate = $true }
    if (-not ($current -match [regex]::Escape($last))) { $needsUpdate = $true }
    if ($needsUpdate) {
        Start-Process notepad $tempFile
        Start-Process explorer "/select,`"$hostsFile`""
        return @("Hosts-файл нужно обновить.", "Открыт Notepad со скачанным содержимым — скопируйте вручную в системный hosts.")
    } else {
        Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
        return @("Hosts-файл уже актуален.")
    }
}

function Invoke-CheckForUpdates {
    $local = Get-LocalVersion
    try {
        $res = Invoke-WebRequest -Uri "https://raw.githubusercontent.com/Flowseal/zapret-discord-youtube/main/.service/version.txt" -TimeoutSec 8 -UseBasicParsing
        $remote = $res.Content.Trim()
    } catch {
        return @("Не удалось проверить обновления: $($_.Exception.Message)")
    }

    if ($local -eq $remote) {
        return @("У вас установлена последняя версия: $local")
    }

    $changelog = $null
    try {
        $releaseInfo = Invoke-RestMethod -Uri "https://api.github.com/repos/Flowseal/zapret-discord-youtube/releases/latest" -TimeoutSec 8 -Headers @{ "User-Agent" = "ZapretGUI" }
        if ($releaseInfo.body) { $changelog = $releaseInfo.body.Trim() }
    } catch {
        # Не критично: если GitHub API недоступен/лимит — просто покажем диалог без списка изменений
    }

    $confirmed = Show-UpdateDialog -LocalVersion $local -RemoteVersion $remote -DestPath $ZapretDir -Changelog $changelog
    if (-not $confirmed) {
        return @("Доступна новая версия: $remote (у вас $local).", "Обновление отменено.")
    }

    $lines = @("Доступна новая версия: $remote (у вас $local).", "Скачиваю...")
    $tempZip = Join-Path $env:TEMP "zapret-update-$remote.zip"
    $tempExtract = Join-Path $env:TEMP "zapret-update-extract-$remote"
    try {
        # Качаем архив напрямую с ветки main (той же, откуда берём version.txt для сравнения версий),
        # без обращения к GitHub Releases API — это убирает целый класс сбоев (нет assets у релиза,
        # временные ошибки/лимиты API, редиректы), из-за которых в $tempZip мог попадать не-zip файл.
        $downloadUrl = "https://github.com/Flowseal/zapret-discord-youtube/archive/refs/heads/main.zip"

        Invoke-WebRequest -Uri $downloadUrl -OutFile $tempZip -TimeoutSec 90 -UserAgent "ZapretGUI"

        if (-not (Test-Path $tempZip) -or (Get-Item $tempZip).Length -lt 10KB) {
            throw "Скачанный файл повреждён или неполный (возможно, обрыв соединения или блокировка антивирусом)."
        }
        try {
            Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
            $zipCheck = [System.IO.Compression.ZipFile]::OpenRead($tempZip)
            $zipCheck.Dispose()
        } catch {
            throw "Скачанный файл не является корректным zip-архивом (повреждён при загрузке)."
        }

        $lines += "Распаковываю..."
        if (Test-Path $tempExtract) { Remove-Item $tempExtract -Recurse -Force -ErrorAction SilentlyContinue }
        Expand-Archive -LiteralPath $tempZip -DestinationPath $tempExtract -Force

        # GitHub кладёt всё в один вложенный подкаталог (например Flowseal-zapret-...-hash) — находим его
        $innerDir = Get-ChildItem -LiteralPath $tempExtract -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $innerDir) { $innerDir = Get-Item -LiteralPath $tempExtract }

        $lines += "Останавливаю текущий обход перед обновлением файлов..."
        try { Stop-Zapret } catch {}
        try { Save-ActiveStrategy -Name $null } catch {}

        # Архив ветки main — это весь репозиторий целиком, а не собранный релиз, поэтому в нём
        # присутствуют служебные файлы git/CI, которые не должны попадать в рабочую папку программы.
        # .service не трогаем — там лежит version.txt, нужный для сравнения версий.
        # .service тоже исключаем: подтверждено по коду (Invoke-IpsetUpdate, Invoke-HostsUpdate,
        # проверка версии) — все три файла программа читает напрямую с GitHub по сети,
        # локальная копия в .service ни для чего не используется.
        $excludeFromCopy = @(".git", ".github", ".gitattributes", ".gitignore", "README.md", "LICENSE", ".service")
        foreach ($itemName in $excludeFromCopy) {
            $itemPath = Join-Path $innerDir.FullName $itemName
            if (Test-Path -LiteralPath $itemPath) {
                Remove-Item -LiteralPath $itemPath -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        $lines += "Заменяю файлы в $ZapretDir ..."
        Copy-Item -Path (Join-Path $innerDir.FullName "*") -Destination $ZapretDir -Recurse -Force

        Remove-Item $tempZip -Force -ErrorAction SilentlyContinue
        Remove-Item $tempExtract -Recurse -Force -ErrorAction SilentlyContinue

        Rebuild-StrategyList
        Refresh-StatusUI
        if ($script:UpdateTray) { & $script:UpdateTray }

        $newVersion = Get-LocalVersion
        $lines += "Готово! Обновлено до версии $newVersion."
        $lines += "Список стратегий обновлён. Выберите и включите нужную заново."
    } catch {
        $lines += "Не удалось обновить автоматически: $($_.Exception.Message)"
        Start-Process "https://github.com/Flowseal/zapret-discord-youtube/releases/latest"
        $lines += "Открыта страница загрузки в браузере — обновите вручную."
    }
    return $lines
}

function Invoke-Diagnostics {
    $lines = @()
    $lines += "Версия zapret: $(Get-LocalVersion)"
    $lines += "winws.exe: " + $(if (Get-Process winws -ErrorAction SilentlyContinue) { "запущен" } else { "не запущен" })
    $svc = Get-Service zapret -ErrorAction SilentlyContinue
    $lines += "Служба zapret: " + $(if ($svc) { $svc.Status } else { "не установлена" })
    $wd = Get-Service WinDivert -ErrorAction SilentlyContinue
    $lines += "WinDivert: " + $(if ($wd) { $wd.Status } else { "не установлен" })
    $conflicts = @("GoodbyeDPI", "discordfix_zapret", "winws1", "winws2") | Where-Object { Get-Service $_ -ErrorAction SilentlyContinue }
    if ($conflicts) {
        $lines += "Конфликтующие службы: $($conflicts -join ', ')"
    } else {
        $lines += "Конфликтующих служб не найдено."
    }
    $lines += "Игровой фильтр: $(Get-GameFilterStatus)"
    $lines += "IPset фильтр: $(Get-IpsetState)"
    $lines += "Автопроверка обновлений: $(Get-CheckUpdatesStatus)"
    return $lines
}

function Invoke-RemoveConflicts {
    $lines = @()
    foreach ($n in @("GoodbyeDPI", "discordfix_zapret", "winws1", "winws2")) {
        $svc = Get-Service $n -ErrorAction SilentlyContinue
        if ($svc) {
            Invoke-ScCommand -Arguments "stop $n"
            Invoke-ScCommand -Arguments "delete $n"
            $lines += "Удалена служба: $n"
        }
    }
    $wd = Get-Service WinDivert -ErrorAction SilentlyContinue
    if ($wd) {
        Invoke-ScCommand -Arguments "stop WinDivert"
        Invoke-ScCommand -Arguments "delete WinDivert"
        $lines += "Удалён WinDivert."
    }
    if ($lines.Count -eq 0) { $lines += "Конфликтующих служб не найдено." }
    return $lines
}

function Get-TestRating {
    param([string[]]$Lines)
    $okCount = 0
    $failCount = 0
    foreach ($l in $Lines) {
        $okCount += ([regex]::Matches($l, ':OK\b')).Count
        $failCount += ([regex]::Matches($l, ':FAIL\b')).Count
        $failCount += ([regex]::Matches($l, ':ERROR\b')).Count
    }
    if ($okCount -eq 0 -and $failCount -eq 0) { return "unknown" }
    if ($failCount -eq 0) { return "good" }
    if ($okCount -eq 0) { return "bad" }
    return "warn"
}

$script:RatingsFile = Join-Path $UtilsDir "gui_ratings.json"
$script:RatingsMap = @{}

function Import-Ratings {
    if (Test-Path $script:RatingsFile) {
        try {
            $data = Get-Content $script:RatingsFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            foreach ($prop in $data.PSObject.Properties) {
                $script:RatingsMap[$prop.Name] = $prop.Value
            }
        } catch {}
    }
}

function Save-Ratings {
    try {
        $script:RatingsMap | ConvertTo-Json | Set-Content -Path $script:RatingsFile -Force -ErrorAction Stop
    } catch {}
}

function Set-StrategyRating {
    param([string]$Name, [string]$Rating, [switch]$NoSave)
    if (-not $Name -or -not $script:StrategyIcons.ContainsKey($Name)) { return }
    $color = switch ($Rating) {
        "good" { "#00E28A" }
        "warn" { "#F5A623" }
        "bad"  { "#FF5C5C" }
        default { "#4A4A57" }
    }
    $script:StrategyIcons[$Name].Fill = [System.Windows.Media.BrushConverter]::new().ConvertFrom($color)
    if (-not $NoSave) {
        $script:RatingsMap[$Name] = $Rating
        Save-Ratings
    }
}

# ---------------------------------------------------------------
# Пакетная проверка всех стратегий подряд (предлагается при первом запуске)
# ---------------------------------------------------------------
$script:BatchActive = $false
$script:BatchQueue = $null
$script:BatchTotal = 0
$script:BatchDone = 0

function Start-BatchTest {
    if ($script:Strategies.Count -eq 0) { return }
    $script:BatchQueue = [System.Collections.Generic.Queue[string]]::new()
    foreach ($s in $script:Strategies) { $script:BatchQueue.Enqueue($s) }
    $script:BatchTotal = $script:BatchQueue.Count
    $script:BatchDone = 0
    $script:BatchActive = $true
    Start-NextBatchItem
}

function Start-NextBatchItem {
    if (-not $script:BatchQueue -or $script:BatchQueue.Count -eq 0) {
        $script:BatchActive = $false
        Update-Log -Clear -Lines @(
            "Проверка всех стратегий завершена ($script:BatchDone из $script:BatchTotal).",
            "Зелёная точка — работает отлично, жёлтая — частично, красная — не работает."
        )
        return
    }
    $next = $script:BatchQueue.Dequeue()
    $script:BatchDone++

    $script:SelectedStrategy = $next
    if ($script:StrategyItems.ContainsKey($next)) {
        foreach ($b in $script:StrategyItems.Values) { $b.Background = [System.Windows.Media.Brushes]::Transparent }
        $script:StrategyItems[$next].Background = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#221F35")
        $script:StrategyItems[$next].BringIntoView()
    }
    $lblSelected.Text = ($next -replace '\.bat$', '')

    Start-TestAsync -StrategyFile $next -BatchLabel "[$script:BatchDone/$script:BatchTotal]"
}

# Убивает зависший "test zapret.ps1" вместе с его дочерними процессами и winws
function Stop-TestProcesses {
    try {
        Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -like '*test zapret.ps1*' } |
            ForEach-Object { & taskkill.exe /PID $_.ProcessId /T /F 2>&1 | Out-Null }
    } catch {}
    Get-Process -Name "winws" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}

$script:TestRetried = $false
$script:LastBatchLabel = ""

function Start-TestAsync {
    param([string]$StrategyFile, [string]$BatchLabel = "", [switch]$IsRetry)
    if (-not $IsRetry) { $script:TestRetried = $false }
    $script:LastBatchLabel = $BatchLabel

    if (-not $StrategyFile) {
        [System.Windows.MessageBox]::Show("Сначала выберите стратегию из списка слева.", "Zapret") | Out-Null
        return
    }

    # Индекс стратегии в списке — ДОЛЖЕН совпадать с тем, как "test zapret.ps1"
    # сам сортирует и нумерует файлы (та же натуральная сортировка), иначе
    # тест выберет не ту стратегию. Совпадает, только если в папке нет наших
    # служебных файлов (ZapretGUI.bat/Build-EXE.bat) — они удаляются установщиком.
    # Список берём ровно так, как его строит сам тест: все *.bat, кроме service*.
    $testNames = @(Get-ChildItem -LiteralPath $ZapretDir -Filter "*.bat" -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notlike "service*" } |
        Sort-Object { [Regex]::Replace($_.Name, '(\d+)', { $args[0].Value.PadLeft(8, '0') }) } |
        Select-Object -ExpandProperty Name)
    $idx = [array]::IndexOf($testNames, $StrategyFile) + 1
    if ($idx -lt 1) {
        [System.Windows.MessageBox]::Show("Не удалось определить номер стратегии.", "Zapret") | Out-Null
        return
    }

    $script:LastTestedStrategy = $StrategyFile
    $btnTest.IsHitTestVisible = $false; if ($gifHost) { $gifHost.Visibility = "Visible" }
    $btnTest.Content = "Выполняется..."
    $prefix = if ($BatchLabel) { "$BatchLabel " } else { "" }
    $retryNote = if ($IsRetry) { " (повторная попытка)" } else { "" }
    Update-Log -Clear -Lines @("$prefix" + "Тестирую стратегию: $($StrategyFile -replace '\.bat$', '')$retryNote", "Это может занять до двух минут, окно останется отзывчивым...")

    $testScript = Join-Path $UtilsDir "test zapret.ps1"

    # НЕ полагаемся на $asyncResult.IsCompleted у PowerShell-инстанса,
    # запущенного через BeginInvoke() в отдельном runspace — это известный
    # баг (PowerShell/PowerShell issue #27251), состояние Completed может
    # никогда не наступить. Сигнализируем через потокобезопасную очередь.
    $resultQueue = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()

    $scriptBlock = {
        param($UtilsDir, $TestScript, $Index, $Queue, $StrategyName, $ZapretDir)

        function Invoke-ScCommandLocal {
            param([string]$Arguments, [int]$TimeoutMs = 4000)
            try {
                $psi = New-Object System.Diagnostics.ProcessStartInfo
                $psi.FileName = "sc.exe"
                $psi.Arguments = $Arguments
                $psi.UseShellExecute = $false
                $psi.CreateNoWindow = $true
                $psi.RedirectStandardOutput = $true
                $psi.RedirectStandardError = $true
                $p = [System.Diagnostics.Process]::Start($psi)
                if (-not $p.WaitForExit($TimeoutMs)) { try { $p.Kill() } catch {} }
            } catch {}
        }

        function Stop-ProcTreeLocal {
            param([int]$ProcId)
            try { & taskkill.exe /PID $ProcId /T /F 2>&1 | Out-Null } catch {}
        }

        # Если тест убили на полпути, он не вернул на место список ipset — возвращаем сами
        function Restore-IpsetLocal {
            try {
                $bak  = Join-Path $ZapretDir "lists\ipset-all.test-backup.txt"
                $lst  = Join-Path $ZapretDir "lists\ipset-all.txt"
                $flag = Join-Path $ZapretDir "ipset_switched.flag"
                if (Test-Path -LiteralPath $bak) { Move-Item -LiteralPath $bak -Destination $lst -Force }
                Remove-Item -LiteralPath $flag -Force -ErrorAction SilentlyContinue
            } catch {}
        }

        function Stop-ZapretLocal {
            Get-Process -Name "winws" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
            $svc = Get-Service -Name "zapret" -ErrorAction SilentlyContinue
            if ($svc) {
                Invoke-ScCommandLocal -Arguments "stop zapret"
                Invoke-ScCommandLocal -Arguments "delete zapret"
            }
            $wd = Get-Service -Name "WinDivert" -ErrorAction SilentlyContinue
            if ($wd) {
                Invoke-ScCommandLocal -Arguments "stop WinDivert"
                Invoke-ScCommandLocal -Arguments "delete WinDivert"
            }
        }

        $noRetry = $false
        try {
            $result = @()
            # Важно: останавливаем именно НАШУ службу заранее, чтобы Windows
            # не перезапускала winws.exe сама, пока test-скрипт переключает
            # стратегии — сам test-скрипт умеет запускать/останавливать
            # процесс winws.exe, но ничего не знает про службы Windows.
            Stop-ZapretLocal
            Restore-IpsetLocal
            Start-Sleep -Milliseconds 500

            if (-not (Test-Path $TestScript)) {
                $result += "Файл теста не найден: $TestScript"
                $Queue.Enqueue(@{ Lines = $result; Rating = "unknown" })
                return
            }

            $tempOut = [System.IO.Path]::GetTempFileName()
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = "cmd.exe"
            $escapedScript = $TestScript.Replace('"', '""')
            $psi.Arguments = "/c powershell -NoProfile -ExecutionPolicy Bypass -File ""$escapedScript"" > ""$tempOut"" 2>&1"
            $psi.WorkingDirectory = $UtilsDir
            $psi.RedirectStandardInput = $true
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true
            $proc = New-Object System.Diagnostics.Process
            $proc.StartInfo = $psi
            [void]$proc.Start()

            # Скрипт задаёт 3 вопроса по порядку:
            #  1) тип теста -> "1" (Standard tests)
            #  2) режим     -> "2" (Selected configs, а не все подряд)
            #  3) какой именно конфиг -> номер выбранной стратегии
            # Все три ответа кладём в канал сразу: он их буферизует, и скрипт прочитает их
            # в своё время. Раньше между ответами стояли фиксированные паузы — на медленном
            # компьютере тест не успевал запуститься, ответы терялись, и результата не было.
            try {
                $proc.StandardInput.WriteLine("1")
                $proc.StandardInput.WriteLine("2")
                $proc.StandardInput.WriteLine("$Index")
                $proc.StandardInput.Flush()
            } catch {}
            try { $proc.StandardInput.Close() } catch {}

            # Жёсткий таймаут — сначала ждём/убиваем процесс, потом читаем
            # накопленный вывод. Скрипт в конце сам пытается сделать
            # ReadKey() на закрытом вводе и упадёт с ошибкой — это ожидаемо
            # и не страшно, нужные результаты уже записаны в файл к этому моменту.
            $exited = $proc.WaitForExit(150000)
            if (-not $exited) {
                # Kill() убивал только cmd.exe, а powershell с тестом и winws оставались жить
                # и ломали следующую проверку — убиваем всё дерево процессов.
                Stop-ProcTreeLocal -ProcId $proc.Id
                $proc.WaitForExit(5000) | Out-Null
                Stop-ZapretLocal
                Restore-IpsetLocal
            }
            Start-Sleep -Milliseconds 300
            $stdout = Get-Content -LiteralPath $tempOut -Raw -ErrorAction SilentlyContinue
            Remove-Item $tempOut -Force -ErrorAction SilentlyContinue

            if ($stdout) {
                $rawLines = $stdout -split "`r?`n"
                $cleanLines = @()
                $okCount = 0
                $failCount = 0
                $stopCapture = $false
                foreach ($line in $rawLines) {
                    $t = $line.Trim()
                    if ($t -eq "") { continue }
                    if ($t.StartsWith("Press any key to close")) { $stopCapture = $true; continue }
                    if ($stopCapture) { continue }
                    if ($t.StartsWith("[OK]") -or $t.StartsWith("[INFO]") -or $t.StartsWith("[WARNING]")) { continue }
                    if ($t.StartsWith("====") -or $t.StartsWith("----")) { continue }
                    if ($t.StartsWith("Select test type") -or $t.StartsWith("[1] Standard") -or $t.StartsWith("[2] DPI")) { continue }
                    if ($t.StartsWith("Select test run mode") -or $t.StartsWith("[1] All configs") -or $t.StartsWith("[2] Selected configs")) { continue }
                    if ($t.StartsWith("Enter 1 or 2") -or $t.StartsWith("Available configs") -or $t.StartsWith("Enter numbers")) { continue }
                    if ($t.StartsWith("ZAPRET CONFIG TESTS") -or $t.StartsWith("Mode:") -or $t.StartsWith("Total configs:")) { continue }
                    if ($t.StartsWith("Targets loaded") -or $t.StartsWith("Tests may take")) { continue }
                    if ($t -match '^\[\d+\]\s') { continue }

                    # Компактный разбор строк результата: "Name  HTTP:OK  TLS1.2:OK  TLS1.3:OK  | Ping: 12 ms"
                    # Статус — любое слово (OK, FAIL, ERROR, SSL, UNSUP и т.п.), не только конкретный список,
                    # чтобы не пропускать ошибки, которые скрипт обозначает не через "FAIL".
                    # Пинг может отсутствовать у некоторых доменов — делаем его необязательным.
                    if ($t -match '^(?<name>\S+)\s+HTTP:(?<http>\S+)\s+TLS1\.2:(?<tls12>\S+)\s+TLS1\.3:(?<tls13>\S+?)(\s*\|\s*Ping:\s*(?<ping>.*?))?\s*$') {
                        $mName = $Matches.name; $mHttp = $Matches.http; $mTls12 = $Matches.tls12; $mTls13 = $Matches.tls13
                        $mPing = if ($Matches.ContainsKey('ping')) { [string]$Matches.ping } else { "" }
                        # UNSUP значит "этот curl не умеет такую проверку" — к провалам обхода не относится
                        foreach ($val in @($mHttp, $mTls12, $mTls13)) {
                            if ($val -eq 'OK') { $okCount++ }
                            elseif ($val -eq 'UNSUP') { }
                            else { $failCount++ }
                        }
                        # Раньше строки с "Ping: Timeout" или "Ping: n/a" не узнавались и выпадали из оценки —
                        # из-за этого проверка то "не срабатывала", то давала неверный цвет.
                        $pingStr = "-"
                        $mPing = $mPing.Trim()
                        if ($mPing -match '^(\d+)\s*ms$') { $pingStr = $Matches[1] + "ms" }
                        elseif ($mPing) { $pingStr = $mPing }
                        $cleanLines += ("{0,-20} H:{1,-6} T2:{2,-6} T3:{3,-6} {4,7}" -f $mName, $mHttp, $mTls12, $mTls13, $pingStr)
                        continue
                    }
                    # Строки без HTTP/TLS, только пинг (напр. CloudflareDNS): "Name   Ping: 12 ms"
                    if ($t -match '^(?<name>\S+)\s*\|?\s*Ping:\s*(?<ping>\d+)\s*ms') {
                        $cleanLines += ("{0,-20} {1,20}" -f $Matches.name, "$($Matches.ping)ms")
                        continue
                    }

                    $cleanLines += $line
                }
                if ($cleanLines.Count -gt 0) {
                    $result += "── $StrategyName ──"
                    $result += $cleanLines
                } else {
                    $result += "Тест выполнен, но результат распознать не удалось."
                }
                if (-not $exited) { $result += "(тест был принудительно остановлен по таймауту 70 сек)" }

                if ($okCount -eq 0 -and $failCount -eq 0) { $rating = "unknown" }
                elseif ($failCount -eq 0) { $rating = "good" }
                elseif ($okCount -eq 0) { $rating = "bad" }
                else { $rating = "warn" }

                if ($stdout -match 'Strategy failed to start') {
                    $result += "Стратегия не запустилась: winws.exe не появился за 5 секунд (антивирус или драйвер WinDivert?)."
                    $rating = "unknown"
                }
                # Проверяем, что тест действительно прогнал именно эту стратегию
                if ($stdout -match '\[\d+/\d+\]\s+(?<cfg>[^\r\n]+?\.bat)') {
                    $ranCfg = $Matches.cfg.Trim()
                    if ($ranCfg -ne ($StrategyName + ".bat")) {
                        $result += "ВНИМАНИЕ: тест запустил другой файл ($ranCfg) — результат не засчитан."
                        $rating = "unknown"
                        $noRetry = $true
                    }
                }
            } else {
                $result += "Тест не вернул данных."
                $rating = "unknown"
            }

            $result += ""
            $result += "Если результат устраивает — нажмите кнопку включения, чтобы применить эту стратегию по-настоящему (через службу)."

            Stop-ZapretLocal
            $Queue.Enqueue(@{ Lines = $result; Rating = $rating; Retry = (-not $noRetry) })
        } catch {
            $Queue.Enqueue(@{ Lines = @("Ошибка во время теста: $($_.Exception.Message)"); Rating = "unknown"; Retry = $true })
        }
    }

    $ps = [PowerShell]::Create()
    $ps.Runspace = [runspacefactory]::CreateRunspace()
    $ps.Runspace.Open()
    [void]$ps.AddScript($scriptBlock).AddArgument($UtilsDir).AddArgument($testScript).AddArgument($idx).AddArgument($resultQueue).AddArgument(($StrategyFile -replace '\.bat$', '')).AddArgument($ZapretDir)
    [void]$ps.BeginInvoke()

    $script:TestPS = $ps
    $script:TestQueue = $resultQueue
    $script:TestStartTime = Get-Date

    $script:TestPollTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:TestPollTimer.Interval = [TimeSpan]::FromMilliseconds(400)
    $script:TestPollTimer.Add_Tick({
      try {
        $item = $null
        if ($script:TestQueue.TryDequeue([ref]$item)) {
            $script:TestPollTimer.Stop()
            try { $script:TestPS.Runspace.Close() } catch {}
            try { $script:TestPS.Dispose() } catch {}
            # Проверка не дала результата (тест не успел стартовать, winws не поднялся и т.п.) — один раз повторяем
            if ($item.Rating -eq "unknown" -and $item.Retry -and -not $script:TestRetried) {
                $script:TestRetried = $true
                Stop-TestProcesses
                Start-TestAsync -StrategyFile $script:LastTestedStrategy -BatchLabel $script:LastBatchLabel -IsRetry
                return
            }
            Update-Log -Lines @($item.Lines)
            Set-StrategyRating -Name $script:LastTestedStrategy -Rating $item.Rating
            $btnTest.Content = "Тест обхода"
            $btnTest.IsHitTestVisible = $true; if ($gifHost) { $gifHost.Visibility = "Collapsed" }
            Refresh-StatusUI
            if ($script:UpdateTray) { & $script:UpdateTray }
            if ($script:BatchActive) { Start-NextBatchItem }
            return
        }
        $secondsElapsed = ((Get-Date) - $script:TestStartTime).TotalSeconds
        if ($secondsElapsed -gt 175) {
            # Аварийная защита: если по каким-то причинам фоновый скрипт
            # так и не положил результат в очередь — не даём GUI висеть вечно.
            $script:TestPollTimer.Stop()
            try { $script:TestPS.Stop() } catch {}
            Stop-TestProcesses
            try {
                $bak = Join-Path $ZapretDir "lists\ipset-all.test-backup.txt"
                if (Test-Path -LiteralPath $bak) { Move-Item -LiteralPath $bak -Destination (Join-Path $ZapretDir "lists\ipset-all.txt") -Force }
                Remove-Item -LiteralPath (Join-Path $ZapretDir "ipset_switched.flag") -Force -ErrorAction SilentlyContinue
            } catch {}
            Update-Log -Lines @("Тест не завершился вовремя — принудительно остановлено.")
            try { $script:TestPS.Runspace.Close() } catch {}
            try { $script:TestPS.Dispose() } catch {}
            $btnTest.Content = "Тест обхода"
            $btnTest.IsHitTestVisible = $true; if ($gifHost) { $gifHost.Visibility = "Collapsed" }
            Refresh-StatusUI
            if ($script:UpdateTray) { & $script:UpdateTray }
            if ($script:BatchActive) { Start-NextBatchItem }
        }
      } catch {
        Update-Log -Lines @(
            "Внутренняя ошибка таймера теста: $($_.Exception.Message)",
            "Строка $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())"
        )
        try { $script:TestPollTimer.Stop() } catch {}
        $script:BatchActive = $false
        $btnTest.Content = "Тест обхода"
        $btnTest.IsHitTestVisible = $true; if ($gifHost) { $gifHost.Visibility = "Collapsed" }
      }
    })
    $script:TestPollTimer.Start()
}

# ---------------------------------------------------------------
# XAML
# ---------------------------------------------------------------
[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Zapret BETA" Height="740" Width="1300"
        MinHeight="740" MinWidth="1300"
        MaxHeight="740" MaxWidth="1300"
        ResizeMode="CanMinimize"
        WindowStartupLocation="CenterScreen"
        Background="#0B0B12" FontFamily="Segoe UI, Segoe UI Emoji, Segoe UI Symbol">
    <Window.Resources>
        <Style TargetType="Button">
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="RenderTransformOrigin" Value="0.5,0.5"/>
            <Setter Property="RenderTransform">
                <Setter.Value>
                    <ScaleTransform ScaleX="1" ScaleY="1"/>
                </Setter.Value>
            </Setter>
            <Style.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                    <Trigger.EnterActions>
                        <BeginStoryboard>
                            <Storyboard>
                                <DoubleAnimation Storyboard.TargetProperty="RenderTransform.ScaleX" To="1.04" Duration="0:0:0.12"/>
                                <DoubleAnimation Storyboard.TargetProperty="RenderTransform.ScaleY" To="1.04" Duration="0:0:0.12"/>
                                <DoubleAnimation Storyboard.TargetProperty="Opacity" To="0.88" Duration="0:0:0.12"/>
                            </Storyboard>
                        </BeginStoryboard>
                    </Trigger.EnterActions>
                    <Trigger.ExitActions>
                        <BeginStoryboard>
                            <Storyboard>
                                <DoubleAnimation Storyboard.TargetProperty="RenderTransform.ScaleX" To="1" Duration="0:0:0.15"/>
                                <DoubleAnimation Storyboard.TargetProperty="RenderTransform.ScaleY" To="1" Duration="0:0:0.15"/>
                                <DoubleAnimation Storyboard.TargetProperty="Opacity" To="1" Duration="0:0:0.15"/>
                            </Storyboard>
                        </BeginStoryboard>
                    </Trigger.ExitActions>
                </Trigger>
            </Style.Triggers>
        </Style>

        <Style x:Key="AnimatedMenuItemStyle" TargetType="MenuItem">
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="Padding" Value="14,8"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="MenuItem">
                        <Border x:Name="ItemBorder" Background="{TemplateBinding Background}" CornerRadius="5" Padding="{TemplateBinding Padding}">
                            <ContentPresenter ContentSource="Header" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsHighlighted" Value="True">
                                <Setter TargetName="ItemBorder" Property="Background" Value="#2A2A3A"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter Property="Foreground" Value="#5A5A66"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="AnimatedContextMenuStyle" TargetType="ContextMenu">
            <Setter Property="Background" Value="#1B1B27"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ContextMenu">
                        <Border x:Name="MenuBorder" Background="{TemplateBinding Background}" CornerRadius="10" Padding="5"
                                RenderTransformOrigin="0.5,0" Opacity="0">
                            <Border.Effect>
                                <DropShadowEffect Color="#000000" Opacity="0.4" BlurRadius="18" ShadowDepth="4"/>
                            </Border.Effect>
                            <Border.RenderTransform>
                                <ScaleTransform ScaleX="1" ScaleY="0.85"/>
                            </Border.RenderTransform>
                            <StackPanel IsItemsHost="True"/>
                            <Border.Triggers>
                                <EventTrigger RoutedEvent="FrameworkElement.Loaded">
                                    <BeginStoryboard>
                                        <Storyboard>
                                            <DoubleAnimation Storyboard.TargetProperty="Opacity" From="0" To="1" Duration="0:0:0.14"/>
                                            <DoubleAnimation Storyboard.TargetProperty="RenderTransform.ScaleY" From="0.85" To="1" Duration="0:0:0.16">
                                                <DoubleAnimation.EasingFunction>
                                                    <QuadraticEase EasingMode="EaseOut"/>
                                                </DoubleAnimation.EasingFunction>
                                            </DoubleAnimation>
                                        </Storyboard>
                                    </BeginStoryboard>
                                </EventTrigger>
                            </Border.Triggers>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
    </Window.Resources>
    <Grid x:Name="rootGrid" RenderTransformOrigin="0.5,0.5">
        <Grid.RenderTransform>
            <TransformGroup>
                <ScaleTransform x:Name="rootScaleTransform" ScaleX="1" ScaleY="1"/>
                <TranslateTransform x:Name="rootShakeTransform" X="0" Y="0"/>
            </TransformGroup>
        </Grid.RenderTransform>
        <Grid.ColumnDefinitions>
            <ColumnDefinition Width="64"/>
            <ColumnDefinition Width="380"/>
            <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>

        <Image x:Name="wallpaperImage" Grid.ColumnSpan="3" Stretch="UniformToFill" Visibility="Collapsed"/>

        <StackPanel x:Name="sidebarPanel" Grid.Column="0" Background="#0F0F17" RenderTransformOrigin="0.5,0.5">
            <StackPanel.RenderTransform>
                <TranslateTransform X="0"/>
            </StackPanel.RenderTransform>
            <Button x:Name="btnAbout" Foreground="#8A8A99" Background="Transparent" BorderThickness="0" Height="56" Margin="0,20,0,0" Cursor="Hand"><Viewbox Width="22" Height="22" IsHitTestVisible="False"><Canvas Width="24" Height="24"><Ellipse Canvas.Left="2" Canvas.Top="2" Width="20" Height="20" Stroke="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Button}}" StrokeThickness="2" StrokeLineJoin="Round" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/><Path Data="M 12,11 L 12,17" Stroke="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Button}}" StrokeThickness="2" StrokeLineJoin="Round" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/><Ellipse Canvas.Left="10.9" Canvas.Top="6" Width="2.2" Height="2.2" Fill="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Button}}"/></Canvas></Viewbox></Button>
            <Button x:Name="btnAdvanced" Foreground="#8A8A99" Background="Transparent" BorderThickness="0" Height="56" Cursor="Hand"><Viewbox Width="22" Height="22" IsHitTestVisible="False"><Canvas Width="24" Height="24"><Path Data="M 10.81,4.49 L 11.04,1.85 L 12.96,1.85 L 13.19,4.49 L 16.47,5.85 L 18.50,4.14 L 19.86,5.50 L 18.15,7.53 L 19.51,10.81 L 22.15,11.04 L 22.15,12.96 L 19.51,13.19 L 18.15,16.47 L 19.86,18.50 L 18.50,19.86 L 16.47,18.15 L 13.19,19.51 L 12.96,22.15 L 11.04,22.15 L 10.81,19.51 L 7.53,18.15 L 5.50,19.86 L 4.14,18.50 L 5.85,16.47 L 4.49,13.19 L 1.85,12.96 L 1.85,11.04 L 4.49,10.81 L 5.85,7.53 L 4.14,5.50 L 5.50,4.14 L 7.53,5.85 Z" Stroke="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Button}}" StrokeThickness="1.8" StrokeLineJoin="Round" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/><Ellipse Canvas.Left="8.6" Canvas.Top="8.6" Width="6.8" Height="6.8" Stroke="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Button}}" StrokeThickness="1.8" StrokeLineJoin="Round" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/></Canvas></Viewbox></Button>
            <Button x:Name="btnDomainFinder" Foreground="#8A8A99" Background="Transparent" BorderThickness="0" Height="56" Cursor="Hand" ToolTip="Определить домены приложения/сайта"><Viewbox Width="21" Height="21" IsHitTestVisible="False"><Canvas Width="24" Height="24"><Ellipse Canvas.Left="3" Canvas.Top="3" Width="13" Height="13" Stroke="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Button}}" StrokeThickness="2" StrokeLineJoin="Round" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/><Path Data="M 14.5,14.5 L 21,21" Stroke="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Button}}" StrokeThickness="2" StrokeLineJoin="Round" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/></Canvas></Viewbox></Button>
            <Button x:Name="btnPlayer" Foreground="#8A8A99" Background="Transparent" BorderThickness="0" Height="56" Cursor="Hand"><Viewbox Width="21" Height="21" IsHitTestVisible="False"><Canvas Width="24" Height="24"><Path Data="M 9,18 L 9,5 L 20,3 L 20,16" Stroke="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Button}}" StrokeThickness="2" StrokeLineJoin="Round" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/><Ellipse Canvas.Left="4" Canvas.Top="15" Width="5" Height="5" Fill="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Button}}"/><Ellipse Canvas.Left="15" Canvas.Top="13" Width="5" Height="5" Fill="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Button}}"/></Canvas></Viewbox></Button>
        </StackPanel>

        <Grid x:Name="leftListPanel" Grid.Column="1" Background="#12121B" RenderTransformOrigin="0.5,0.5">
            <Grid.RenderTransform>
                <TranslateTransform X="0"/>
            </Grid.RenderTransform>
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
            </Grid.RowDefinitions>
            <Grid Grid.Row="0" Margin="24,24,24,16">
                <StackPanel Orientation="Horizontal" VerticalAlignment="Bottom">
                    <TextBlock Text="Стратегии" Foreground="White" FontSize="26" FontWeight="Bold"/>
                    <Border Background="#3A2A1A" CornerRadius="4" Padding="7,3" Margin="10,0,0,4" VerticalAlignment="Bottom">
                        <TextBlock Text="BETA" Foreground="#F5A623" FontSize="11" FontWeight="Bold"/>
                    </Border>
                </StackPanel>
                <TextBlock x:Name="btnCheckAll" Text="Проверить все" Foreground="#B39CE8" FontSize="13" FontWeight="SemiBold"
                           VerticalAlignment="Bottom" HorizontalAlignment="Right" Cursor="Hand" TextDecorations="Underline"/>
            </Grid>
            <Border Grid.Row="1" Background="#1B1B27" CornerRadius="8" Margin="24,0,24,16" Height="38">
                <TextBox x:Name="txtSearch" Background="Transparent" Foreground="White" BorderThickness="0" VerticalContentAlignment="Center" Padding="10,0" FontSize="13"/>
            </Border>
            <ScrollViewer Grid.Row="2" VerticalScrollBarVisibility="Auto" Margin="16,0,16,16">
                <StackPanel x:Name="listPanel"/>
            </ScrollViewer>
        </Grid>

        <Grid x:Name="mainContentPanel" Grid.Column="2" Background="#0B0B12" RenderTransformOrigin="0.5,0.5">
            <Grid.RenderTransform>
                <TranslateTransform X="0"/>
            </Grid.RenderTransform>
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
                <RowDefinition Height="220"/>
                <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>

            <Border x:Name="activeStrategyBadge" Grid.Row="0" HorizontalAlignment="Left" Margin="32,24,0,0" Background="#151520" CornerRadius="6" Padding="12,7">
                <StackPanel Orientation="Horizontal">
                    <Ellipse x:Name="activeDot" Width="8" Height="8" Fill="#4A4A57" VerticalAlignment="Center" Margin="0,0,8,0"/>
                    <TextBlock x:Name="activeStrategyText" Text="Ничего не запущено" Foreground="#B7B7C2" FontSize="12" VerticalAlignment="Center"/>
                </StackPanel>
            </Border>

            <StackPanel Grid.Row="0" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,24,32,0">
                <Border Background="#151F1B" CornerRadius="6" Padding="12,7" VerticalAlignment="Center">
                    <StackPanel Orientation="Horizontal">
                        <Ellipse Width="8" Height="8" Fill="#00E28A" VerticalAlignment="Center" Margin="0,0,8,0"/>
                        <TextBlock Text="Служба · автозапуск с Windows" Foreground="#B7B7C2" FontSize="12" VerticalAlignment="Center"/>
                    </StackPanel>
                </Border>
                <Border x:Name="avatarBorder" Width="40" Height="40" CornerRadius="20" Background="#1B1B27"
                        Margin="14,0,0,0" Cursor="Hand" VerticalAlignment="Center" ToolTip="Изменить аватар">
                    <Viewbox x:Name="avatarPlaceholder" Width="20" Height="20" HorizontalAlignment="Center" VerticalAlignment="Center"><Canvas Width="24" Height="24"><Ellipse Canvas.Left="7.5" Canvas.Top="3" Width="9" Height="9" Stroke="#6B6B78" StrokeThickness="2"/><Path Data="M 4,21 C 4,15.5 20,15.5 20,21" Stroke="#6B6B78" StrokeThickness="2" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/></Canvas></Viewbox>
                </Border>
            </StackPanel>

            <Grid Grid.Row="1">
                <StackPanel x:Name="mainView" VerticalAlignment="Center" HorizontalAlignment="Center">
                    <Border x:Name="powerCircle" Width="190" Height="190" CornerRadius="95" Background="#15151F"
                            BorderThickness="2" Cursor="Hand" RenderTransformOrigin="0.5,0.5">
                        <Border.RenderTransform>
                            <ScaleTransform ScaleX="1" ScaleY="1"/>
                        </Border.RenderTransform>
                        <Border.BorderBrush>
                            <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                                <GradientStop Color="#8E44E0" Offset="0"/>
                                <GradientStop Color="#E63950" Offset="1"/>
                            </LinearGradientBrush>
                        </Border.BorderBrush>
                        <!-- Значок питания нарисован линиями, а не символом шрифта: глиф U+23FB есть не во всех версиях
                             Windows (на старых вместо него пустая рамка). Foreground по-прежнему перекрашивается из кода. -->
                        <ContentControl x:Name="powerIcon" HorizontalAlignment="Center" VerticalAlignment="Center" IsTabStop="False" Focusable="False">
                            <ContentControl.Foreground>
                                <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                                    <GradientStop Color="#8E44E0" Offset="0"/>
                                    <GradientStop Color="#E63950" Offset="1"/>
                                </LinearGradientBrush>
                            </ContentControl.Foreground>
                            <Path x:Name="powerPath" Data="M 40,12.68 A 20,20 0 1 1 20,12.68 M 30,8 L 30,30" Width="60" Height="60"
                                  Stroke="{Binding Foreground, RelativeSource={RelativeSource AncestorType=ContentControl}}"
                                  StrokeThickness="6" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"/>
                        </ContentControl>
                    </Border>
                    <TextBlock x:Name="lblSelected" Text="Стратегия не выбрана" Foreground="White" FontSize="18" FontWeight="SemiBold"
                               HorizontalAlignment="Center" Margin="0,24,0,4"/>
                    <TextBlock x:Name="lblStatus" Text="Отключено" Foreground="#8A8A99" FontSize="13"
                               HorizontalAlignment="Center" Margin="0,0,0,24"/>
                    <Grid Width="180" Height="42">
                        <Button x:Name="btnTest" Content="Тест обхода" Width="180" Height="42" Foreground="White"
                                BorderThickness="0" FontSize="14" Cursor="Hand">
                            <Button.Background>
                                <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                                    <GradientStop Color="#8E44E0" Offset="0"/>
                                    <GradientStop Color="#E63950" Offset="1"/>
                                </LinearGradientBrush>
                            </Button.Background>
                        </Button>
                        <Border x:Name="gifHost" Width="180" Height="42" CornerRadius="8" Background="#15151F" Visibility="Collapsed"/>
                    </Grid>
                    <TextBlock x:Name="uptimeText" Text="" Foreground="#8A8A99" FontSize="12.5" HorizontalAlignment="Center" Margin="0,14,0,0"/>
                </StackPanel>

                <ScrollViewer x:Name="settingsView" VerticalScrollBarVisibility="Auto" Visibility="Collapsed" Margin="24,10,24,10">
                    <StackPanel>
                        <Button x:Name="btnBack" Content="&#8592; Назад" HorizontalAlignment="Left" Background="Transparent" Foreground="#8A8A99" BorderThickness="0" FontSize="14" Margin="0,0,0,16" Cursor="Hand"/>
                        <TextBlock Text="Расширенные настройки" Foreground="White" FontSize="22" FontWeight="Bold" Margin="0,0,0,16"/>

                        <TextBlock Text="СТАТУС СИСТЕМЫ" Foreground="Gray" FontSize="11" Margin="0,0,0,6"/>
                        <Button x:Name="btnStatus" Content="Показать статус" Height="34" Margin="0,0,0,18" Background="#1B1B27" Foreground="White" BorderThickness="0" HorizontalAlignment="Left" Padding="16,0" Cursor="Hand"/>

                        <TextBlock Text="ИГРОВОЙ ФИЛЬТР" Foreground="Gray" FontSize="11" Margin="0,0,0,6"/>
                        <StackPanel Orientation="Horizontal" Margin="0,0,0,10">
                            <ComboBox x:Name="cmbGameFilter" Width="180" Height="32" Background="#1B1B27" Foreground="Black">
                                <ComboBoxItem Content="Выключен" IsSelected="True"/>
                                <ComboBoxItem Content="TCP и UDP"/>
                                <ComboBoxItem Content="Только TCP"/>
                                <ComboBoxItem Content="Только UDP"/>
                            </ComboBox>
                            <Button x:Name="btnApplyGameFilter" Content="Применить" Height="32" Margin="10,0,0,0" Foreground="White" BorderThickness="0" Padding="14,0" Cursor="Hand">
                                <Button.Background>
                                    <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                                        <GradientStop Color="#8E44E0" Offset="0"/>
                                        <GradientStop Color="#E63950" Offset="1"/>
                                    </LinearGradientBrush>
                                </Button.Background>
                            </Button>
                        </StackPanel>
                        <StackPanel Orientation="Horizontal" Margin="0,0,0,4">
                            <TextBlock Text="TCP порты:" Foreground="#8A8A99" FontSize="12" Width="80" VerticalAlignment="Center"/>
                            <TextBox x:Name="txtGameFilterTcp" Width="220" Height="28" Background="#1B1B27" Foreground="White" BorderThickness="0" Padding="8,4" Text="1024-65535"/>
                            <Button x:Name="btnGameFilterTcpDefault" Content="По умолчанию" Height="28" Margin="8,0,0,0" Background="#1B1B27" Foreground="#8A8A99" BorderThickness="0" FontSize="11" Padding="10,0" Cursor="Hand"/>
                        </StackPanel>
                        <StackPanel Orientation="Horizontal" Margin="0,0,0,4">
                            <TextBlock Text="UDP порты:" Foreground="#8A8A99" FontSize="12" Width="80" VerticalAlignment="Center"/>
                            <TextBox x:Name="txtGameFilterUdp" Width="220" Height="28" Background="#1B1B27" Foreground="White" BorderThickness="0" Padding="8,4" Text="1024-65535"/>
                            <Button x:Name="btnGameFilterUdpDefault" Content="По умолчанию" Height="28" Margin="8,0,0,0" Background="#1B1B27" Foreground="#8A8A99" BorderThickness="0" FontSize="11" Padding="10,0" Cursor="Hand"/>
                        </StackPanel>
                        <TextBlock Text="Например, чтобы исключить RTMP (порт 1935): 1024-1934,1936-65535" Foreground="#5E5E6B" FontSize="10.5" TextWrapping="Wrap" Margin="0,2,0,18"/>

                        <TextBlock Text="FAKE-ФАЙЛЫ UDP (ПОДМЕНА АКТИВНЫХ)" Foreground="Gray" FontSize="11" Margin="0,0,0,6"/>
                        <StackPanel Orientation="Horizontal" Margin="0,0,0,6">
                            <TextBlock Text="Discord UDP:" Foreground="#8A8A99" FontSize="12" Width="120" VerticalAlignment="Center"/>
                            <ComboBox x:Name="cmbFakeDiscord" Width="250" Height="30" Background="#1B1B27" Foreground="Black"/>
                        </StackPanel>
                        <StackPanel Orientation="Horizontal" Margin="0,0,0,8">
                            <TextBlock Text="Игровой фильтр UDP:" Foreground="#8A8A99" FontSize="12" Width="120" VerticalAlignment="Center" TextWrapping="Wrap"/>
                            <ComboBox x:Name="cmbFakeGame" Width="250" Height="30" Background="#1B1B27" Foreground="Black"/>
                        </StackPanel>
                        <Button x:Name="btnApplyFakes" Content="Применить" Height="32" HorizontalAlignment="Left" Foreground="White" BorderThickness="0" Padding="16,0" Margin="0,0,0,6" Cursor="Hand">
                            <Button.Background>
                                <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                                    <GradientStop Color="#8E44E0" Offset="0"/>
                                    <GradientStop Color="#E63950" Offset="1"/>
                                </LinearGradientBrush>
                            </Button.Background>
                        </Button>
                        <TextBlock x:Name="txtFakeStatus" Text="" Foreground="#8A8A99" FontSize="11.5" TextWrapping="Wrap" Margin="0,0,0,2"/>
                        <TextBlock Text="Подменяет «активные» поддельные UDP/QUIC-пакеты, которые стратегии отправляют для Discord и игрового фильтра (файлы ACTIVE_DISCORD_UDP.bin и ACTIVE_GAME_UDP.bin в папке bin). Пригодится, если стандартный вариант не работает у вашего провайдера. Галочка ✓ отмечает файл, который сейчас активен. После применения активная стратегия перезапустится." Foreground="#5E5E6B" FontSize="10.5" TextWrapping="Wrap" Margin="0,0,0,18"/>

                        <TextBlock Text="IPSET ФИЛЬТР" Foreground="Gray" FontSize="11" Margin="0,0,0,6"/>
                        <Button x:Name="btnIpsetToggle" Content="Переключить режим" Height="34" Margin="0,0,0,18" Background="#1B1B27" Foreground="White" BorderThickness="0" HorizontalAlignment="Left" Padding="16,0" Cursor="Hand"/>

                        <TextBlock Text="DNS (ОБХОД ПОДМЕНЫ ПРОВАЙДЕРОМ)" Foreground="Gray" FontSize="11" Margin="0,0,0,6"/>
                        <StackPanel Orientation="Horizontal" Margin="0,0,0,8">
                            <ComboBox x:Name="cmbDnsProvider" Width="270" Height="32" Background="#1B1B27" Foreground="Black"/>
                            <Button x:Name="btnApplyDns" Content="Применить" Height="32" Margin="10,0,0,0" Foreground="White" BorderThickness="0" Padding="14,0" Cursor="Hand">
                                <Button.Background>
                                    <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                                        <GradientStop Color="#8E44E0" Offset="0"/>
                                        <GradientStop Color="#E63950" Offset="1"/>
                                    </LinearGradientBrush>
                                </Button.Background>
                            </Button>
                            <Button x:Name="btnResetDns" Content="Вернуть как было" Height="32" Margin="8,0,0,0" Background="#1B1B27" Foreground="#D8D8E0" BorderThickness="0" Padding="12,0" Cursor="Hand"/>
                        </StackPanel>
                        <TextBlock x:Name="txtDnsInfo" Text="" Foreground="#8A8A99" FontSize="11" TextWrapping="Wrap" Margin="0,0,0,8"/>
                        <StackPanel x:Name="panelDnsCustom" Visibility="Collapsed" Margin="0,0,0,8">
                            <TextBlock Text="Адреса DNS (через запятую или пробел, IPv4/IPv6):" Foreground="#8A8A99" FontSize="11.5" Margin="0,0,0,4"/>
                            <TextBox x:Name="txtDnsCustom" Width="320" Height="30" HorizontalAlignment="Left" Background="#1B1B27" Foreground="White" BorderThickness="0" Padding="8,5" ToolTip="Например: 1.1.1.1, 1.0.0.1"/>
                            <TextBlock Text="Шаблон DoH (необязательно, https://…/dns-query):" Foreground="#8A8A99" FontSize="11.5" Margin="0,8,0,4"/>
                            <TextBox x:Name="txtDnsCustomDoh" Width="320" Height="30" HorizontalAlignment="Left" Background="#1B1B27" Foreground="White" BorderThickness="0" Padding="8,5" ToolTip="Для известных провайдеров (Cloudflare, Google, Quad9, AdGuard) подставится автоматически"/>
                        </StackPanel>
                        <CheckBox x:Name="chkDnsDoh" Content="Шифровать запросы (DoH)" IsChecked="True" Foreground="#B7B7C2" FontSize="12" Margin="0,0,0,6"/>
                        <TextBlock x:Name="txtDnsStatus" Text="" Foreground="#8A8A99" FontSize="11.5" TextWrapping="Wrap" Margin="0,0,0,2"/>
                        <TextBlock Text="Список серверов составлен по разделу «Безопасные DNS-серверы» на comss.ru. Меняет DNS у активных сетевых адаптеров для всех программ. Помогает, когда провайдер подменяет ответы DNS и сайт не открывается даже при работающем zapret. Нужного сервера нет в списке — выберите «Свой DNS…». После смены перезапустите браузер." Foreground="#5E5E6B" FontSize="10.5" TextWrapping="Wrap" Margin="0,0,0,18"/>

                        <TextBlock Text="ЗАЩИТА ПАПКИ ПРОГРАММЫ" Foreground="Gray" FontSize="11" Margin="0,0,0,6"/>
                        <StackPanel Orientation="Horizontal" Margin="0,0,0,8">
                            <Button x:Name="btnLockFolder" Content="Закрыть папку" Height="32" Foreground="White" BorderThickness="0" Padding="14,0" Cursor="Hand">
                                <Button.Background>
                                    <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                                        <GradientStop Color="#8E44E0" Offset="0"/>
                                        <GradientStop Color="#E63950" Offset="1"/>
                                    </LinearGradientBrush>
                                </Button.Background>
                            </Button>
                            <Button x:Name="btnUnlockFolder" Content="Открыть доступ" Height="32" Margin="8,0,0,0" Background="#1B1B27" Foreground="#D8D8E0" BorderThickness="0" Padding="12,0" Cursor="Hand"/>
                        </StackPanel>
                        <TextBlock x:Name="txtLockStatus" Text="" Foreground="#8A8A99" FontSize="11.5" TextWrapping="Wrap" Margin="0,0,0,8"/>
                        <StackPanel Orientation="Horizontal" Margin="0,0,0,8">
                            <Button x:Name="btnOpenListsFolder" Content="Папка списков" Height="30" Background="#1B1B27" Foreground="#D8D8E0" BorderThickness="0" Padding="12,0" Cursor="Hand"/>
                            <Button x:Name="btnOpenPlaylistFolderSettings" Content="Папка плейлиста" Height="30" Margin="8,0,0,0" Background="#1B1B27" Foreground="#D8D8E0" BorderThickness="0" Padding="12,0" Cursor="Hand"/>
                        </StackPanel>
                        <TextBlock Text="Скрывает папку zapret и закрывает её от обычных пользователей Windows. Доступ остаётся к спискам (lists) и плейлисту. Это защита от случайного захода: пользователь с правами администратора сможет открыть папку, подтвердив запрос UAC." Foreground="#5E5E6B" FontSize="10.5" TextWrapping="Wrap" Margin="0,0,0,18"/>

                        <TextBlock Text="АВТОПРОВЕРКА ОБНОВЛЕНИЙ" Foreground="Gray" FontSize="11" Margin="0,0,0,6"/>
                        <Button x:Name="btnToggleAutoCheck" Content="Вкл / Выкл" Height="34" Margin="0,0,0,18" Background="#1B1B27" Foreground="White" BorderThickness="0" HorizontalAlignment="Left" Padding="16,0" Cursor="Hand"/>

                        <TextBlock Text="ОБСЛУЖИВАНИЕ" Foreground="Gray" FontSize="11" Margin="0,0,0,6"/>
                        <WrapPanel Margin="0,0,0,18">
                            <Button x:Name="btnUpdateIpset" Content="Обновить список IP" Height="34" Margin="0,0,10,8" Background="#1B1B27" Foreground="White" BorderThickness="0" Padding="14,0" Cursor="Hand"/>
                            <Button x:Name="btnUpdateHosts" Content="Обновить hosts" Height="34" Margin="0,0,10,8" Background="#1B1B27" Foreground="White" BorderThickness="0" Padding="14,0" Cursor="Hand"/>
                            <Button x:Name="btnCheckUpdates" Content="Проверить обновления" Height="34" Margin="0,0,10,8" Background="#1B1B27" Foreground="White" BorderThickness="0" Padding="14,0" Cursor="Hand"/>
                        </WrapPanel>

                        <TextBlock Text="ОПАСНАЯ ЗОНА" Foreground="#FF6B6B" FontSize="11" Margin="0,0,0,6"/>
                        <WrapPanel>
                            <Button x:Name="btnRemoveConflicts" Content="Удалить конфликтующие службы" Height="34" Margin="0,0,10,8" Background="#3A1F1F" Foreground="#FF9B9B" BorderThickness="0" Padding="14,0" Cursor="Hand"/>
                            <Button x:Name="btnRemoveService" Content="Удалить службу zapret" Height="34" Margin="0,0,10,8" Background="#3A1F1F" Foreground="#FF9B9B" BorderThickness="0" Padding="14,0" Cursor="Hand"/>
                        </WrapPanel>
                    </StackPanel>
                </ScrollViewer>
            </Grid>

            <Border Grid.Row="2" Background="#12121B" CornerRadius="8" Margin="24,0,24,10">
                <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto">
                    <TextBox x:Name="logBox" Background="Transparent" Foreground="#9BE38A" FontFamily="Cascadia Mono, Consolas" FontSize="12.5"
                             BorderThickness="0" IsReadOnly="True" TextWrapping="NoWrap" AcceptsReturn="True" Padding="14,12"/>
                </ScrollViewer>
            </Border>

            <TextBlock Grid.Row="3" Text="zapret-discord-youtube · GUI" Foreground="#4A4A57" FontSize="11"
                       HorizontalAlignment="Center" Margin="0,0,0,10"/>

            <Border x:Name="wallpaperTab" Grid.Row="0" Grid.RowSpan="4" Width="34" Height="90" CornerRadius="8,0,0,8"
                    HorizontalAlignment="Right" VerticalAlignment="Bottom" Margin="0,0,0,60" Cursor="Hand">
                <Border.Background>
                    <LinearGradientBrush x:Name="wallpaperTabBrush" StartPoint="0,0" EndPoint="0,1">
                        <GradientStop x:Name="wallpaperTabStop1" Color="#E63950" Offset="0"/>
                        <GradientStop x:Name="wallpaperTabStop2" Color="#8E44E0" Offset="1"/>
                    </LinearGradientBrush>
                </Border.Background>
                <TextBlock Text="&#127912;" FontSize="15" HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>

            <MediaElement x:Name="mediaPlayer" LoadedBehavior="Manual" UnloadedBehavior="Manual" Visibility="Collapsed"/>

            <Border x:Name="playerPanel" Grid.Row="0" Grid.RowSpan="4" Width="300" CornerRadius="12" Background="#151520"
                    HorizontalAlignment="Left" VerticalAlignment="Bottom" Margin="24,0,0,70" Visibility="Collapsed">
                <StackPanel Margin="16,12">
                    <Grid>
                        <TextBlock x:Name="playerTrackName" Text="Плеер" Foreground="White" FontSize="13" FontWeight="SemiBold"
                                   VerticalAlignment="Center" TextTrimming="CharacterEllipsis" Margin="0,0,24,0"/>
                        <Border x:Name="btnPlayerClose" Background="Transparent" HorizontalAlignment="Right" VerticalAlignment="Center" Cursor="Hand" Padding="8,4">
                            <Path Data="M 6,0 L 0,6.5 L 6,13" Stroke="#8A8A99" StrokeThickness="2" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"/>
                        </Border>
                    </Grid>
                    <StackPanel Orientation="Horizontal" Margin="0,12,0,0" HorizontalAlignment="Center">
                        <Button x:Name="btnPlayerPrev" Width="34" Height="34" Background="#2A2A38" Foreground="White" BorderThickness="0" Margin="0,0,8,0">
                            <Path Data="M 0,0 L 2.5,0 L 2.5,12 L 0,12 Z M 14,0 L 14,12 L 4.5,6 Z" Fill="White" Stretch="Uniform" Width="13" Height="13"/>
                        </Button>
                        <Button x:Name="btnPlayerToggle" Width="40" Height="40" Background="#2A2A38" Foreground="White" BorderThickness="0">
                            <Grid>
                                <Path x:Name="playerPlayIcon" Data="M 0,0 L 11,6.5 L 0,13 Z" Fill="White" Stretch="Uniform" Width="14" Height="14" Margin="2,0,0,0"/>
                                <Path x:Name="playerPauseIcon" Data="M 0,0 L 4,0 L 4,13 L 0,13 Z M 8,0 L 12,0 L 12,13 L 8,13 Z" Fill="White" Stretch="Uniform" Width="14" Height="14" Visibility="Collapsed"/>
                            </Grid>
                        </Button>
                        <Button x:Name="btnPlayerNext" Width="34" Height="34" Background="#2A2A38" Foreground="White" BorderThickness="0" Margin="8,0,0,0">
                            <Path Data="M 11.5,0 L 14,0 L 14,12 L 11.5,12 Z M 0,0 L 9.5,6 L 0,12 Z" Fill="White" Stretch="Uniform" Width="13" Height="13"/>
                        </Button>
                    </StackPanel>
                    <StackPanel Orientation="Horizontal" Margin="0,10,0,0">
                        <TextBlock Text="&#128266;" FontSize="13" Foreground="#8A8A99" VerticalAlignment="Center" Margin="0,0,8,0"/>
                        <Slider x:Name="volumeSlider" Width="220" Minimum="0" Maximum="1" Value="0.5" VerticalAlignment="Center"/>
                    </StackPanel>

                    <Grid Margin="0,14,0,6">
                        <TextBlock x:Name="playerTracksHeader" Text="ТРЕКИ" Foreground="#8A8A99" FontSize="10.5" VerticalAlignment="Center"/>
                        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
                            <Button x:Name="btnPlayerOpenFolder" Content="Папка" Height="24" Padding="10,0" Margin="0,0,6,0"
                                    Background="#2A2A38" Foreground="#B7B7C2" BorderThickness="0" FontSize="11" Cursor="Hand"/>
                            <Button x:Name="btnPlayerRefresh" Content="&#8635; Обновить" Height="24" Padding="10,0"
                                    Background="#2A2A38" Foreground="White" BorderThickness="0" FontSize="11" Cursor="Hand"/>
                        </StackPanel>
                    </Grid>

                    <TextBlock x:Name="playerEmptyHint" Text="Плейлист пуст. Положите mp3-файлы в папку assets\playlist и нажмите «Обновить»."
                               Foreground="#8A8A99" FontSize="11.5" TextWrapping="Wrap" Margin="2,6,2,4" Visibility="Collapsed"/>

                    <ListBox x:Name="lstPlayerTracks" MaxHeight="190" Background="Transparent" BorderThickness="0" FontSize="12"
                             ScrollViewer.HorizontalScrollBarVisibility="Disabled" ScrollViewer.VerticalScrollBarVisibility="Auto">
                        <ListBox.ItemTemplate>
                            <DataTemplate>
                                <TextBlock Text="{Binding}" ToolTip="{Binding}" TextTrimming="CharacterEllipsis"/>
                            </DataTemplate>
                        </ListBox.ItemTemplate>
                        <ListBox.ItemContainerStyle>
                            <Style TargetType="ListBoxItem">
                                <Setter Property="Foreground" Value="#D8D8E0"/>
                                <Setter Property="Padding" Value="8,6"/>
                                <Setter Property="Cursor" Value="Hand"/>
                                <Setter Property="Template">
                                    <Setter.Value>
                                        <ControlTemplate TargetType="ListBoxItem">
                                            <Border x:Name="itemBd" Background="Transparent" CornerRadius="6" Padding="{TemplateBinding Padding}">
                                                <ContentPresenter/>
                                            </Border>
                                            <ControlTemplate.Triggers>
                                                <Trigger Property="IsMouseOver" Value="True">
                                                    <Setter TargetName="itemBd" Property="Background" Value="#22222F"/>
                                                </Trigger>
                                                <Trigger Property="IsSelected" Value="True">
                                                    <Setter TargetName="itemBd" Property="Background" Value="#2E2548"/>
                                                    <Setter Property="Foreground" Value="White"/>
                                                </Trigger>
                                            </ControlTemplate.Triggers>
                                        </ControlTemplate>
                                    </Setter.Value>
                                </Setter>
                            </Style>
                        </ListBox.ItemContainerStyle>
                    </ListBox>
                    <TextBlock Text="Двойной клик по треку — включить" Foreground="#5E5E6B" FontSize="10" Margin="2,6,0,0"/>
                </StackPanel>
            </Border>
        </Grid>

        <Border x:Name="wallpaperOverlay" Grid.ColumnSpan="3" Background="#00000000" Visibility="Collapsed">
            <Grid>
                <Button x:Name="btnWallpaperBack" Content="&#8592; Назад" HorizontalAlignment="Left" VerticalAlignment="Top" Margin="20,20,0,0"
                        Height="34" Padding="14,0" Background="#1B1B27" Foreground="#D8D8E0" BorderThickness="0" FontSize="13" Cursor="Hand"/>
                <StackPanel HorizontalAlignment="Center" VerticalAlignment="Center">
                    <TextBlock Text="Оформление" Foreground="White" FontSize="22" FontWeight="Bold" HorizontalAlignment="Center" Margin="0,0,0,6"/>
                    <TextBlock Text="Выберите изображение для фона приложения" Foreground="#8A8A99" FontSize="13" HorizontalAlignment="Center" Margin="0,0,0,26"/>
                    <Button x:Name="btnSetWallpaper" Content="Установить обои" Width="220" Height="46" Foreground="White" BorderThickness="0" FontSize="14.5">
                        <Button.Background>
                            <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                                <GradientStop Color="#8E44E0" Offset="0"/>
                                <GradientStop Color="#E63950" Offset="1"/>
                            </LinearGradientBrush>
                        </Button.Background>
                    </Button>
                    <Button x:Name="btnRemoveWallpaper" Content="Убрать обои" Width="220" Height="40" Background="#1B1B27" Foreground="#B7B7C2" BorderThickness="0" FontSize="13" Margin="0,12,0,0" Visibility="Collapsed"/>
                </StackPanel>
            </Grid>
        </Border>

        <Border x:Name="introBorder" Grid.ColumnSpan="3" BorderThickness="6" IsHitTestVisible="False" Opacity="0">
            <Border.BorderBrush>
                <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                    <GradientStop Color="#E63950" Offset="0"/>
                    <GradientStop Color="#8E44E0" Offset="0.5"/>
                    <GradientStop Color="#3AD1FF" Offset="1"/>
                </LinearGradientBrush>
            </Border.BorderBrush>
            <Border.Effect>
                <DropShadowEffect Color="#B026FF" BlurRadius="35" ShadowDepth="0" Opacity="0.9"/>
            </Border.Effect>
        </Border>

        <Rectangle x:Name="introScanLine" Grid.ColumnSpan="3" Height="3" VerticalAlignment="Top"
                   IsHitTestVisible="False" Opacity="0">
            <Rectangle.Fill>
                <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
                    <GradientStop Color="#003AD1FF" Offset="0"/>
                    <GradientStop Color="#FF3AD1FF" Offset="0.5"/>
                    <GradientStop Color="#003AD1FF" Offset="1"/>
                </LinearGradientBrush>
            </Rectangle.Fill>
            <Rectangle.RenderTransform>
                <TranslateTransform x:Name="introScanTransform" Y="0"/>
            </Rectangle.RenderTransform>
        </Rectangle>

        <Border x:Name="musicGlowBorder" Grid.ColumnSpan="3" BorderThickness="4" IsHitTestVisible="False" Opacity="0">
            <Border.BorderBrush>
                <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                    <GradientStop Color="#3AD1FF" Offset="0"/>
                    <GradientStop Color="#B026FF" Offset="0.5"/>
                    <GradientStop Color="#E63950" Offset="1"/>
                </LinearGradientBrush>
            </Border.BorderBrush>
            <Border.Effect>
                <DropShadowEffect Color="#B026FF" BlurRadius="28" ShadowDepth="0" Opacity="0.85"/>
            </Border.Effect>
        </Border>

        <Border x:Name="introFlash" Grid.ColumnSpan="3" Background="#FFFFFFFF" IsHitTestVisible="False" Opacity="0"/>

        <Rectangle x:Name="introStreak1" Grid.ColumnSpan="3" Width="5" Height="600" Fill="#3AD1FF"
                   IsHitTestVisible="False" Opacity="0" HorizontalAlignment="Left" VerticalAlignment="Top" Margin="180,-80,0,0">
            <Rectangle.RenderTransform>
                <RotateTransform Angle="24"/>
            </Rectangle.RenderTransform>
            <Rectangle.Effect>
                <BlurEffect Radius="5"/>
            </Rectangle.Effect>
        </Rectangle>

        <Rectangle x:Name="introStreak2" Grid.ColumnSpan="3" Width="5" Height="500" Fill="#E63950"
                   IsHitTestVisible="False" Opacity="0" HorizontalAlignment="Right" VerticalAlignment="Bottom" Margin="0,0,260,-60">
            <Rectangle.RenderTransform>
                <RotateTransform Angle="-22"/>
            </Rectangle.RenderTransform>
            <Rectangle.Effect>
                <BlurEffect Radius="5"/>
            </Rectangle.Effect>
        </Rectangle>

        <Rectangle x:Name="introStreak3" Grid.ColumnSpan="3" Width="4" Height="450" Fill="#B026FF"
                   IsHitTestVisible="False" Opacity="0" HorizontalAlignment="Center" VerticalAlignment="Top" Margin="120,-40,0,0">
            <Rectangle.RenderTransform>
                <RotateTransform Angle="14"/>
            </Rectangle.RenderTransform>
            <Rectangle.Effect>
                <BlurEffect Radius="5"/>
            </Rectangle.Effect>
        </Rectangle>
    </Grid>
</Window>
"@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)

$listPanel   = $window.FindName("listPanel")
$txtSearch   = $window.FindName("txtSearch")
$btnCheckAll = $window.FindName("btnCheckAll")
$sidebarPanel = $window.FindName("sidebarPanel")
$leftListPanel = $window.FindName("leftListPanel")
$mainContentPanel = $window.FindName("mainContentPanel")
$powerCircle = $window.FindName("powerCircle")
$powerIcon   = $window.FindName("powerIcon")
$powerPath   = $window.FindName("powerPath")
$lblSelected = $window.FindName("lblSelected")
$lblStatus   = $window.FindName("lblStatus")
$btnTest     = $window.FindName("btnTest")
$gifHost     = $window.FindName("gifHost")
$avatarBorder = $window.FindName("avatarBorder")
$avatarPlaceholder = $window.FindName("avatarPlaceholder")
$activeStrategyBadge = $window.FindName("activeStrategyBadge")
$activeDot = $window.FindName("activeDot")
$activeStrategyText = $window.FindName("activeStrategyText")
$uptimeText = $window.FindName("uptimeText")
$wallpaperImage = $window.FindName("wallpaperImage")
$wallpaperTab = $window.FindName("wallpaperTab")
$wallpaperTabStop1 = $window.FindName("wallpaperTabStop1")
$wallpaperTabStop2 = $window.FindName("wallpaperTabStop2")
$wallpaperOverlay = $window.FindName("wallpaperOverlay")
$btnSetWallpaper = $window.FindName("btnSetWallpaper")
$btnRemoveWallpaper = $window.FindName("btnRemoveWallpaper")
$btnWallpaperBack = $window.FindName("btnWallpaperBack")
$rootShakeTransform = $window.FindName("rootShakeTransform")
$introBorder = $window.FindName("introBorder")
$introScanLine = $window.FindName("introScanLine")
$introScanTransform = $window.FindName("introScanTransform")
$introFlash = $window.FindName("introFlash")
$introStreak1 = $window.FindName("introStreak1")
$introStreak2 = $window.FindName("introStreak2")
$introStreak3 = $window.FindName("introStreak3")
$rootScaleTransform = $window.FindName("rootScaleTransform")
$btnPlayer = $window.FindName("btnPlayer")
$mediaPlayer = $window.FindName("mediaPlayer")
$musicGlowBorder = $window.FindName("musicGlowBorder")
$playerPanel = $window.FindName("playerPanel")
$playerTrackName = $window.FindName("playerTrackName")
$btnPlayerPrev = $window.FindName("btnPlayerPrev")
$btnPlayerToggle = $window.FindName("btnPlayerToggle")
$btnPlayerNext = $window.FindName("btnPlayerNext")
$btnPlayerClose = $window.FindName("btnPlayerClose")
$playerPlayIcon = $window.FindName("playerPlayIcon")
$playerPauseIcon = $window.FindName("playerPauseIcon")
$btnPlayerRefresh = $window.FindName("btnPlayerRefresh")
$btnPlayerOpenFolder = $window.FindName("btnPlayerOpenFolder")
$lstPlayerTracks = $window.FindName("lstPlayerTracks")
$playerTracksHeader = $window.FindName("playerTracksHeader")
$playerEmptyHint = $window.FindName("playerEmptyHint")
$volumeSlider = $window.FindName("volumeSlider")

# --- Анимированный индикатор загрузки на время теста (GIF через WinForms PictureBox,
#     т.к. штатный WPF Image не умеет анимировать GIF) ---
try {
    [System.Reflection.Assembly]::LoadWithPartialName("WindowsFormsIntegration") | Out-Null
    $gifPath = Join-Path $ZapretDir "assets\spongebob-fast.gif"
    if (Test-Path $gifPath) {
        $pictureBox = New-Object System.Windows.Forms.PictureBox
        $pictureBox.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::Zoom
        $pictureBox.Image = [System.Drawing.Image]::FromFile($gifPath)
        $pictureBox.BackColor = [System.Drawing.Color]::Transparent
        $wfHost = New-Object System.Windows.Forms.Integration.WindowsFormsHost
        $wfHost.Child = $pictureBox
        $gifHost.Child = $wfHost
    }
} catch {}
$btnAdvanced = $window.FindName("btnAdvanced")
$btnDomainFinder = $window.FindName("btnDomainFinder")
$btnAbout    = $window.FindName("btnAbout")
$mainView    = $window.FindName("mainView")
$settingsView= $window.FindName("settingsView")
$btnBack     = $window.FindName("btnBack")
$logBox      = $window.FindName("logBox")
$btnStatus   = $window.FindName("btnStatus")
$cmbGameFilter = $window.FindName("cmbGameFilter")
$btnApplyGameFilter = $window.FindName("btnApplyGameFilter")
$txtGameFilterTcp = $window.FindName("txtGameFilterTcp")
$txtGameFilterUdp = $window.FindName("txtGameFilterUdp")
$btnGameFilterTcpDefault = $window.FindName("btnGameFilterTcpDefault")
$btnGameFilterUdpDefault = $window.FindName("btnGameFilterUdpDefault")
$btnIpsetToggle = $window.FindName("btnIpsetToggle")
$cmbDnsProvider = $window.FindName("cmbDnsProvider")
$btnApplyDns = $window.FindName("btnApplyDns")
$btnResetDns = $window.FindName("btnResetDns")
$chkDnsDoh = $window.FindName("chkDnsDoh")
$panelDnsCustom = $window.FindName("panelDnsCustom")
$txtDnsInfo = $window.FindName("txtDnsInfo")
$txtDnsCustom = $window.FindName("txtDnsCustom")
$txtDnsCustomDoh = $window.FindName("txtDnsCustomDoh")
$cmbFakeDiscord = $window.FindName("cmbFakeDiscord")
$cmbFakeGame = $window.FindName("cmbFakeGame")
$btnApplyFakes = $window.FindName("btnApplyFakes")
$txtFakeStatus = $window.FindName("txtFakeStatus")
$btnLockFolder = $window.FindName("btnLockFolder")
$btnUnlockFolder = $window.FindName("btnUnlockFolder")
$txtLockStatus = $window.FindName("txtLockStatus")
$btnOpenListsFolder = $window.FindName("btnOpenListsFolder")
$btnOpenPlaylistFolderSettings = $window.FindName("btnOpenPlaylistFolderSettings")
$txtDnsStatus = $window.FindName("txtDnsStatus")
$btnToggleAutoCheck = $window.FindName("btnToggleAutoCheck")
$btnUpdateIpset = $window.FindName("btnUpdateIpset")
$btnUpdateHosts = $window.FindName("btnUpdateHosts")
$btnCheckUpdates = $window.FindName("btnCheckUpdates")
$btnRemoveConflicts = $window.FindName("btnRemoveConflicts")
$btnRemoveService = $window.FindName("btnRemoveService")

function Update-Log {
    param([string[]]$Lines, [switch]$Clear)
    if ($Clear) { $logBox.Clear() }
    foreach ($l in $Lines) { [void]$logBox.AppendText("$l`r`n") }
    $logBox.ScrollToEnd()
}
function Force-Render {
    $window.Dispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Background) | Out-Null
}

$script:Strategies = @(Get-Strategies)
$script:SelectedStrategy = $null
$script:StrategyItems = @{}
$script:StrategyIcons = @{}
$script:LastTestedStrategy = $null

function New-StrategyItem {
    param([string]$Name)
    $border = New-Object System.Windows.Controls.Border
    $border.CornerRadius = 8
    $border.Background = [System.Windows.Media.Brushes]::Transparent
    $border.Padding = "14,10"
    $border.Margin = "0,2"
    $border.Cursor = "Hand"
    $border.Tag = $Name

    $stack = New-Object System.Windows.Controls.StackPanel
    $stack.Orientation = "Horizontal"

    $icon = New-Object System.Windows.Shapes.Ellipse
    $icon.Width = 9
    $icon.Height = 9
    $icon.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#4A4A57")
    $icon.Margin = "0,0,12,0"
    $icon.VerticalAlignment = "Center"
    $script:StrategyIcons[$Name] = $icon

    $text = New-Object System.Windows.Controls.TextBlock
    $text.Text = ($Name -replace '\.bat$', '')
    $text.Foreground = [System.Windows.Media.Brushes]::White
    $text.FontSize = 13
    $text.VerticalAlignment = "Center"
    $text.TextWrapping = "Wrap"
    $text.Width = 300

    [void]$stack.Children.Add($icon)
    [void]$stack.Children.Add($text)
    $border.Child = $stack

    $border.Add_MouseLeftButtonUp({
        param($s, $e)
        $name = $s.Tag
        foreach ($b in $script:StrategyItems.Values) {
            $b.Background = [System.Windows.Media.Brushes]::Transparent
        }
        $s.Background = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#221F35")
        $script:SelectedStrategy = $name
        $lblSelected.Text = ($name -replace '\.bat$', '')
    })

    return $border
}

function Rebuild-StrategyList {
    $listPanel.Children.Clear()
    $script:StrategyItems = @{}
    $script:StrategyIcons = @{}
    $script:Strategies = @(Get-Strategies)

    if ($script:Strategies.Count -gt 0) {
        for ($i = 0; $i -lt $script:Strategies.Count; $i++) {
            $item = New-StrategyItem -Name $script:Strategies[$i]
            [void]$listPanel.Children.Add($item)
            $script:StrategyItems[$script:Strategies[$i]] = $item
        }
        Import-Ratings
        foreach ($name in $script:RatingsMap.Keys) {
            if ($script:StrategyIcons.ContainsKey($name)) {
                Set-StrategyRating -Name $name -Rating $script:RatingsMap[$name] -NoSave
            }
        }
        $script:SelectedStrategy = $script:Strategies[0]
        $lblSelected.Text = ($script:Strategies[0] -replace '\.bat$', '')
        $script:StrategyItems[$script:Strategies[0]].Background = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#221F35")
    }
}

Rebuild-StrategyList

if ($btnCheckAll) {
    $btnCheckAll.Add_MouseLeftButtonUp({
        if ($script:BatchActive) { return }
        Start-BatchTest
    })
}

$txtSearch.Add_TextChanged({
    $q = $txtSearch.Text.ToLower()
    foreach ($name in $script:StrategyItems.Keys) {
        $script:StrategyItems[$name].Visibility = if ($name.ToLower().Contains($q)) { "Visible" } else { "Collapsed" }
    }
})

function New-AccentBrush {
    $b = New-Object System.Windows.Media.LinearGradientBrush
    $b.StartPoint = New-Object System.Windows.Point(0, 0)
    $b.EndPoint = New-Object System.Windows.Point(1, 1)
    $c1 = [System.Windows.Media.ColorConverter]::ConvertFromString("#8E44E0")
    $c2 = [System.Windows.Media.ColorConverter]::ConvertFromString("#E63950")
    [void]$b.GradientStops.Add((New-Object System.Windows.Media.GradientStop($c1, 0)))
    [void]$b.GradientStops.Add((New-Object System.Windows.Media.GradientStop($c2, 1)))
    return $b
}

$script:ActiveStrategyFile = Join-Path $UtilsDir "gui_active_strategy.txt"
$script:ActiveStrategyName = $null

function Save-ActiveStrategy {
    param([string]$Name)
    $script:ActiveStrategyName = $Name
    try {
        if ($Name) { Set-Content -Path $script:ActiveStrategyFile -Value $Name -Force }
        else { Remove-Item $script:ActiveStrategyFile -Force -ErrorAction SilentlyContinue }
    } catch {}
}

function Import-ActiveStrategy {
    if (Test-Path $script:ActiveStrategyFile) {
        $val = (Get-Content $script:ActiveStrategyFile -Raw -ErrorAction SilentlyContinue)
        if ($val) { $script:ActiveStrategyName = $val.Trim() }
    }
}

function Update-ActiveStrategyBadge {
    $s = Get-ZapretStatus
    if ($s.On -and $script:ActiveStrategyName) {
        $activeStrategyText.Text = "Активна: $($script:ActiveStrategyName)"
        $activeDot.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#00E28A")
    } else {
        $activeStrategyText.Text = "Ничего не запущено"
        $activeDot.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#4A4A57")
    }
}

function Update-Uptime {
    try {
        $p = Get-Process -Name "winws" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($p) {
            $elapsed = (Get-Date) - $p.StartTime
            $h = [int][Math]::Floor($elapsed.TotalHours)
            $uptimeText.Text = "{0:D2}:{1:D2}:{2:D2}" -f $h, $elapsed.Minutes, $elapsed.Seconds
        } else {
            $uptimeText.Text = ""
        }
    } catch { $uptimeText.Text = "" }
}

function Refresh-StatusUI {
    $s = Get-ZapretStatus
    $lblStatus.Text = $s.Text
    if ($s.On) {
        $powerCircle.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#00E28A")
        $powerIcon.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#00E28A")
    } else {
        $powerCircle.BorderBrush = New-AccentBrush
        $powerIcon.Foreground = New-AccentBrush
    }
    # красим значок питания напрямую: так он не зависит от наследования Foreground
    if ($powerPath) { $powerPath.Stroke = $powerIcon.Foreground }
    Update-ActiveStrategyBadge
    Update-Uptime
}

function Start-ToggleZapret {
    if (-not $script:SelectedStrategy) {
        if ($script:Strategies.Count -gt 0) {
            $script:SelectedStrategy = $script:Strategies[0]
            $lblSelected.Text = ($script:Strategies[0] -replace '\.bat$', '')
        } else {
            [System.Windows.MessageBox]::Show("Стратегии не найдены.", "Zapret") | Out-Null
            return
        }
    }
    $status = Get-ZapretStatus
    if ($status.On) {
        Stop-Zapret
        Save-ActiveStrategy -Name $null
    } else {
        Stop-Zapret
        Start-Sleep -Milliseconds 400
        $idx = [array]::IndexOf($script:Strategies, $script:SelectedStrategy) + 1
        $res = Install-ZapretService -Index $idx
        if (-not $res.Success) {
            Update-Log -Clear -Lines (@("Не удалось установить службу автозапуска.", "Вывод service.bat:") + ($res.Log -split "`r?`n" | Where-Object { $_.Trim() -ne "" }))
            Save-ActiveStrategy -Name $null
        } else {
            Save-ActiveStrategy -Name ($script:SelectedStrategy -replace '\.bat$', '')
        }
    }
    Start-Sleep -Seconds 2
    Refresh-StatusUI
    if ($script:UpdateTray) { & $script:UpdateTray }
}

function Invoke-ClickBounce {
    param($Element)
    try {
        $scale = $Element.RenderTransform
        $anim = New-Object System.Windows.Media.Animation.DoubleAnimation
        $anim.From = 1
        $anim.To = 0.92
        $anim.Duration = [TimeSpan]::FromMilliseconds(90)
        $anim.AutoReverse = $true
        $scale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty, $anim)
        $scale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, $anim)
    } catch {}
}

function Switch-View {
    param($From, $To)
    try {
        $script:FadeFrom = $From
        $script:FadeTo = $To
        $script:FadeTo.Opacity = 0
        $script:FadeTo.Visibility = "Visible"

        $fadeOut = New-Object System.Windows.Media.Animation.DoubleAnimation
        $fadeOut.From = 1
        $fadeOut.To = 0
        $fadeOut.Duration = [TimeSpan]::FromMilliseconds(140)
        $fadeOut.add_Completed({
            $script:FadeFrom.Visibility = "Collapsed"
            $fadeIn = New-Object System.Windows.Media.Animation.DoubleAnimation
            $fadeIn.From = 0
            $fadeIn.To = 1
            $fadeIn.Duration = [TimeSpan]::FromMilliseconds(180)
            $script:FadeTo.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $fadeIn)
        })
        $script:FadeFrom.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $fadeOut)
    } catch {
        $From.Visibility = "Collapsed"
        $To.Visibility = "Visible"
        $To.Opacity = 1
    }
}

$powerCircle.Add_MouseLeftButtonUp({
    Invoke-ClickBounce -Element $powerCircle
    try { Start-ToggleZapret }
    catch { Update-Log -Clear -Lines @("Ошибка включения/выключения: $($_.Exception.Message)") }
})

$btnTest.Add_Click({
    try {
        Start-TestAsync -StrategyFile $script:SelectedStrategy
    } catch {
        Update-Log -Clear -Lines @("Ошибка запуска теста: $($_.Exception.Message)")
        $btnTest.Content = "Тест обхода"
        $btnTest.IsHitTestVisible = $true; if ($gifHost) { $gifHost.Visibility = "Collapsed" }
    }
})

$btnAdvanced.Add_Click({
    $cfg = Get-GameFilterConfig
    $modeIndexMap = @{ "disabled" = 0; "all" = 1; "tcp" = 2; "udp" = 3 }
    $cmbGameFilter.SelectedIndex = if ($modeIndexMap.ContainsKey($cfg.Mode)) { $modeIndexMap[$cfg.Mode] } else { 0 }
    $txtGameFilterTcp.Text = $cfg.TcpRange
    $txtGameFilterUdp.Text = $cfg.UdpRange
    Update-DnsPanel
    Update-LockPanel
    Update-FakesPanel
    Switch-View -From $mainView -To $settingsView
})

$btnDomainFinder.Add_Click({
    Show-DomainFinderDialog
})
$btnBack.Add_Click({
    Switch-View -From $settingsView -To $mainView
})

$btnStatus.Add_Click({ Update-Log -Clear -Lines (Invoke-Diagnostics) })

$btnGameFilterTcpDefault.Add_Click({ $txtGameFilterTcp.Text = "1024-65535" })
$btnGameFilterUdpDefault.Add_Click({ $txtGameFilterUdp.Text = "1024-65535" })

$btnApplyGameFilter.Add_Click({
    $modeMap = @("disabled", "all", "tcp", "udp")
    $sel = $cmbGameFilter.SelectedIndex
    if ($sel -lt 0) { $sel = 0 }
    $mode = $modeMap[$sel]
    $tcpRange = $txtGameFilterTcp.Text.Trim()
    $udpRange = $txtGameFilterUdp.Text.Trim()

    if ($mode -ne "disabled") {
        $needTcp = ($mode -eq "all" -or $mode -eq "tcp")
        $needUdp = ($mode -eq "all" -or $mode -eq "udp")
        if ($needTcp -and -not (Test-GameFilterRange -Range $tcpRange)) {
            Update-Log -Clear -Lines @("Неверный формат TCP-портов. Пример: 1024-65535 или 1024-1934,1936-65535")
            return
        }
        if ($needUdp -and -not (Test-GameFilterRange -Range $udpRange)) {
            Update-Log -Clear -Lines @("Неверный формат UDP-портов. Пример: 1024-65535 или 1024-1934,1936-65535")
            return
        }
    }

    Save-GameFilterSettings -Mode $mode -TcpRange $tcpRange -UdpRange $udpRange

    $status = Get-ZapretStatus
    if ($status.On -and $script:SelectedStrategy) {
        Update-Log -Clear -Lines @("Игровой фильтр обновлён: $(Get-GameFilterStatus)", "Перезапуск стратегии для применения изменений...")
        Stop-Zapret
        Start-Sleep -Milliseconds 500
        $idx = [array]::IndexOf($script:Strategies, $script:SelectedStrategy) + 1
        $res = Install-ZapretService -Index $idx
        Start-Sleep -Seconds 1
        Refresh-StatusUI
        if ($script:UpdateTray) { & $script:UpdateTray }
        if ($res.Success) {
            Update-Log -Lines @("Готово, стратегия перезапущена с новым фильтром.")
        } else {
            Update-Log -Lines @("Не удалось перезапустить автоматически — включите стратегию вручную.")
        }
    } else {
        Update-Log -Clear -Lines @("Игровой фильтр обновлён: $(Get-GameFilterStatus)")
    }
})

# ---------------- Подмена активных fake-файлов (пункт 7 «Replace active fakes» из service.bat) ----------------
# В папке bin лежат два "активных" файла: ACTIVE_DISCORD_UDP.bin и ACTIVE_GAME_UDP.bin — поддельные UDP/QUIC-пакеты,
# которые стратегии отправляют для Discord и для игрового фильтра. Остальные .bin — готовые варианты на замену.
# Текущий вариант определяется по хешу файла (как и в service.bat).
$script:BinDir = Join-Path $ZapretDir "bin"

function Get-FakeCandidates {
    $items = @()
    if (-not (Test-Path -LiteralPath $script:BinDir)) { return @() }
    foreach ($f in (Get-ChildItem -LiteralPath $script:BinDir -File -Filter "*.bin" -ErrorAction SilentlyContinue | Sort-Object Name)) {
        if ($f.BaseName -like "ACTIVE_*") { continue }
        $h = ""
        try { $h = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256 -ErrorAction Stop).Hash } catch {}
        $items += [PSCustomObject]@{ Name = $f.BaseName; Path = $f.FullName; Hash = $h }
    }
    return $items
}

function Get-FileHashSafe {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return "" }
    try { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash } catch { return "" }
}

# Копируем во временный файл и подменяем — если копирование оборвётся, рабочий файл не пострадает
function Set-ActiveFakeFile {
    param([string]$ActiveName, [string]$SourcePath)
    $active = Join-Path $script:BinDir $ActiveName
    $tmp = $active + ".new"
    try {
        Copy-Item -LiteralPath $SourcePath -Destination $tmp -Force -ErrorAction Stop
        Move-Item -LiteralPath $tmp -Destination $active -Force -ErrorAction Stop
    } catch {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        throw
    }
}

function Update-FakesPanel {
    try {
        $cands = @(Get-FakeCandidates)
        $specs = @(
            @{ Combo = $cmbFakeDiscord; Active = "ACTIVE_DISCORD_UDP.bin" },
            @{ Combo = $cmbFakeGame;    Active = "ACTIVE_GAME_UDP.bin" }
        )
        foreach ($spec in $specs) {
            $combo = $spec.Combo
            $combo.Items.Clear()
            $activePath = Join-Path $script:BinDir $spec.Active
            $actHash = Get-FileHashSafe -Path $activePath
            $curName = ""
            foreach ($c in $cands) {
                if ($actHash -and ($c.Hash -eq $actHash)) { $curName = $c.Name; break }
            }
            $ph = New-Object System.Windows.Controls.ComboBoxItem
            if ($curName) { $ph.Content = "(оставить текущий: $curName)" }
            elseif ($actHash) { $ph.Content = "(текущий — свой файл, оставить)" }
            else { $ph.Content = "(файл $($spec.Active) не найден)" }
            [void]$combo.Items.Add($ph)
            foreach ($c in $cands) {
                $it = New-Object System.Windows.Controls.ComboBoxItem
                $mark = ""
                if ($c.Name -eq $curName) { $mark = ([string][char]0x2713) + " " }
                $it.Content = $mark + $c.Name
                $it.Tag = $c.Path
                [void]$combo.Items.Add($it)
            }
            $combo.SelectedIndex = 0
        }
        if ($cands.Count -eq 0) { $txtFakeStatus.Text = "В папке bin не найдено .bin-файлов." } else { $txtFakeStatus.Text = "" }
    } catch {}
}

$btnApplyFakes.Add_Click({
    try {
        $btnApplyFakes.IsEnabled = $false
        $txtFakeStatus.Text = "Применяю..."
        Force-Render

        # 1) что именно нужно поменять (выбранный файл совпадает с активным — пропускаем)
        $specs = @(
            @{ Combo = $cmbFakeDiscord; Active = "ACTIVE_DISCORD_UDP.bin"; Title = "Discord UDP" },
            @{ Combo = $cmbFakeGame;    Active = "ACTIVE_GAME_UDP.bin";    Title = "Игровой фильтр UDP" }
        )
        $changes = @()
        foreach ($spec in $specs) {
            $item = $spec.Combo.SelectedItem
            if ((-not $item) -or (-not $item.Tag)) { continue }
            $src = [string]$item.Tag
            $srcHash = Get-FileHashSafe -Path $src
            $actHash = Get-FileHashSafe -Path (Join-Path $script:BinDir $spec.Active)
            if ($srcHash -and ($srcHash -eq $actHash)) { continue }
            $changes += [PSCustomObject]@{ Active = $spec.Active; Title = $spec.Title; Source = $src; Name = [System.IO.Path]::GetFileNameWithoutExtension($src) }
        }
        if ($changes.Count -eq 0) {
            $txtFakeStatus.Text = "Менять нечего: выбраны текущие файлы."
            return
        }

        # 2) стратегию на время замены останавливаем — вдруг файл занят работающей службой
        $status = Get-ZapretStatus
        $wasOn = ($status.On -and $script:SelectedStrategy)
        if ($wasOn) {
            $txtFakeStatus.Text = "Останавливаю стратегию на время замены..."
            Force-Render
            Stop-Zapret
            Start-Sleep -Milliseconds 500
        }

        # 3) замена
        $done = @()
        $errs = @()
        foreach ($c in $changes) {
            try {
                Set-ActiveFakeFile -ActiveName $c.Active -SourcePath $c.Source
                $done += ("{0} → {1}" -f $c.Title, $c.Name)
            } catch {
                $errs += ("{0}: {1}" -f $c.Title, $_.Exception.Message)
            }
        }

        # 4) возвращаем стратегию, если она работала
        $restartNote = ""
        if ($wasOn) {
            $idx = [array]::IndexOf($script:Strategies, $script:SelectedStrategy) + 1
            $res = Install-ZapretService -Index $idx
            Start-Sleep -Seconds 1
            Refresh-StatusUI
            if ($script:UpdateTray) { & $script:UpdateTray }
            if ($res.Success) { $restartNote = " Стратегия перезапущена." }
            else { $restartNote = " Не удалось перезапустить стратегию автоматически — включите её вручную." }
        } else {
            $restartNote = " Изменения вступят в силу при следующем запуске стратегии."
        }

        $msg = ""
        if ($done.Count -gt 0) { $msg = "Готово: " + ($done -join "; ") + "." + $restartNote }
        if ($errs.Count -gt 0) { $msg += " Ошибки: " + ($errs -join "; ") }
        Update-Log -Lines @("Fake-файлы: " + $msg.Trim())
        # сначала обновляем списки (там помечается новый активный файл ✓), и только потом показываем итог —
        # иначе обновление списков стёрло бы строку статуса
        Update-FakesPanel
        $txtFakeStatus.Text = $msg.Trim()
    } catch {
        $txtFakeStatus.Text = "Ошибка: $($_.Exception.Message)"
    } finally {
        $btnApplyFakes.IsEnabled = $true
    }
})

# ---------------- DNS: смена серверов у активных адаптеров (+ DoH на Windows 11) ----------------
# Многие провайдеры подменяют ответы DNS. zapret обходит блокировку по SNI/TCP, но DNS не лечит,
# поэтому сайт может не открываться даже при работающей стратегии. Порядок = порядку в списке cmbDnsProvider.
# Источник: comss.ru/list.php?c=securedns (страницы сервисов и инструкция «DNS-over-HTTPS в Windows 11»).
#   V4/V6   — адреса обычного DNS;
#   Doh     — шаблон DoH (если сайт его указывает);
#   DohIps  — адреса, для которых регистрируется шаблон DoH (если не задано — все V4+V6);
#   DnsWithDoh — какие адреса ставить адаптеру, когда включён DoH (если не задано — те же V4+V6).
$script:DnsProviders = @(
    @{ Name = "Comss.one DNS";
       V4 = @("83.220.169.155", "212.109.195.93"); V6 = @();
       Doh = "https://dns.comss.one/dns-query";
       DohIps = @("83.220.169.155", "195.133.25.16");
       DnsWithDoh = @("83.220.169.155", "195.133.25.16") },
    @{ Name = "Яндекс.DNS — Базовый";
       V4 = @("77.88.8.8", "77.88.8.1"); V6 = @("2a02:6b8::feed:0ff", "2a02:6b8:0:1::feed:0ff");
       Doh = "https://common.dot.dns.yandex.net/dns-query"; DohIps = @("77.88.8.8") },
    @{ Name = "Яндекс.DNS — Безопасный";
       V4 = @("77.88.8.88", "77.88.8.2"); V6 = @("2a02:6b8::feed:bad", "2a02:6b8:0:1::feed:bad");
       Doh = "https://safe.dot.dns.yandex.net/dns-query"; DohIps = @("77.88.8.88") },
    @{ Name = "Яндекс.DNS — Семейный";
       V4 = @("77.88.8.3", "77.88.8.7"); V6 = @("2a02:6b8::feed:a11", "2a02:6b8:0:1::feed:a11");
       Doh = "https://family.dot.dns.yandex.net/dns-query"; DohIps = @("77.88.8.7") },
    @{ Name = "Gcore Public DNS";
       V4 = @("95.85.95.85", "2.56.220.2"); V6 = @("2a03:90c0:999d::1", "2a03:90c0:9992::1"); Doh = $null },
    @{ Name = "AdGuard DNS — Стандартный";
       V4 = @("94.140.14.14", "94.140.15.15"); V6 = @("2a10:50c0::ad1:ff", "2a10:50c0::ad2:ff");
       Doh = "https://dns.adguard-dns.com/dns-query" },
    @{ Name = "AdGuard DNS — Без фильтрации";
       V4 = @("94.140.14.140", "94.140.14.141"); V6 = @("2a10:50c0::1:ff", "2a10:50c0::2:ff");
       Doh = "https://unfiltered.adguard-dns.com/dns-query" },
    @{ Name = "AdGuard DNS — Семейный";
       V4 = @("94.140.14.15", "94.140.15.16"); V6 = @("2a10:50c0::bad1:ff", "2a10:50c0::bad2:ff");
       Doh = "https://family.adguard-dns.com/dns-query" },
    @{ Name = "Cloudflare DNS (1.1.1.1)";
       V4 = @("1.1.1.1", "1.0.0.1"); V6 = @("2606:4700:4700::1111", "2606:4700:4700::1001");
       Doh = "https://cloudflare-dns.com/dns-query" },
    @{ Name = "Google Public DNS (8.8.8.8)";
       V4 = @("8.8.8.8", "8.8.4.4"); V6 = @("2001:4860:4860::8888", "2001:4860:4860::8844");
       Doh = "https://dns.google/dns-query" },
    @{ Name = "Quad9 (9.9.9.9)";
       V4 = @("9.9.9.9", "149.112.112.112"); V6 = @("2620:fe::fe", "2620:fe::9");
       Doh = "https://dns.quad9.net/dns-query" }
)

# Заполняем выпадающий список из данных выше + последний пункт «Свой DNS…»
foreach ($p in $script:DnsProviders) {
    $it = New-Object System.Windows.Controls.ComboBoxItem
    $it.Content = $p.Name
    [void]$cmbDnsProvider.Items.Add($it)
}
$itCustom = New-Object System.Windows.Controls.ComboBoxItem
$itCustom.Content = "Свой DNS…"
[void]$cmbDnsProvider.Items.Add($itCustom)
$cmbDnsProvider.SelectedIndex = 0

# Строка под списком: какие адреса будут установлены
function Get-DnsProviderInfoText {
    param([int]$Index)
    if (($Index -lt 0) -or ($Index -ge $script:DnsProviders.Count)) { return "" }
    $p = $script:DnsProviders[$Index]
    $txt = "Адреса: " + ((@($p.V4) + @($p.V6)) -join ", ")
    if ($p.Doh) { $txt += "`nDoH: " + $p.Doh } else { $txt += "`nDoH для этого сервера не указан — будет обычный DNS" }
    return $txt
}
$script:DnsBackupFile = Join-Path $UtilsDir "dns_backup.json"

$script:DnsCustomFile = Join-Path $UtilsDir "dns_custom.json"

# Разбирает и проверяет введённые пользователем адреса. Возвращает объект такой же формы, как элементы
# $script:DnsProviders (Name/V4/V6/Doh), либо объект с полем Error.
function Get-DnsCustomProvider {
    param([string]$AddressText, [string]$DohText)
    $tokens = @(([string]$AddressText -split '[,;\s]+') | Where-Object { $_ })
    if ($tokens.Count -eq 0) { return [PSCustomObject]@{ Error = "Введите хотя бы один адрес DNS (например: 1.1.1.1, 1.0.0.1)." } }
    if ($tokens.Count -gt 6) { return [PSCustomObject]@{ Error = "Слишком много адресов — укажите не больше 6." } }

    $v4 = @(); $v6 = @()
    foreach ($t in $tokens) {
        $ip = $null
        # IPAddress.TryParse принимает и странные формы вроде "1" или "1.1" — для IPv4 требуем полный вид a.b.c.d
        $looksV4 = ($t -match '^\d{1,3}(\.\d{1,3}){3}$')
        if (($t -notmatch ':') -and (-not $looksV4)) { return [PSCustomObject]@{ Error = "«$t» — не похоже на IP-адрес (нужен вид 1.1.1.1 или 2606:4700:4700::1111)." } }
        if (-not [System.Net.IPAddress]::TryParse($t, [ref]$ip)) { return [PSCustomObject]@{ Error = "«$t» — не похоже на IP-адрес." } }
        if ($ip.Equals([System.Net.IPAddress]::Any) -or $ip.Equals([System.Net.IPAddress]::IPv6Any) -or $ip.Equals([System.Net.IPAddress]::Broadcast)) {
            return [PSCustomObject]@{ Error = "Адрес $t не подходит для DNS." }
        }
        if ($ip.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) { $v4 += $ip.ToString() } else { $v6 += $ip.ToString() }
    }

    $doh = ""
    $dt = ([string]$DohText).Trim()
    if ($dt) {
        $u = $null
        if ((-not [Uri]::TryCreate($dt, [UriKind]::Absolute, [ref]$u)) -or ($u.Scheme -ne "https")) {
            return [PSCustomObject]@{ Error = "Шаблон DoH должен быть ссылкой вида https://dns.example/dns-query" }
        }
        $doh = $dt
    } else {
        # Если адрес принадлежит известному провайдеру — шаблон DoH подставим сами
        foreach ($p in $script:DnsProviders) {
            $pAll = @($p.V4) + @($p.V6)
            if ($p.DohIps) { $pAll += @($p.DohIps) }
            if ($p.DnsWithDoh) { $pAll += @($p.DnsWithDoh) }
            foreach ($s in ($v4 + $v6)) { if ($pAll -contains $s) { $doh = $p.Doh; break } }
            if ($doh) { break }
        }
    }
    return [PSCustomObject]@{ Error = $null; Name = ("свой (" + (($v4 + $v6) -join ", ") + ")"); V4 = $v4; V6 = $v6; Doh = $doh }
}

function Save-DnsCustom {
    param([string]$Addresses, [string]$Doh)
    try { (ConvertTo-Json -InputObject ([PSCustomObject]@{ Addresses = $Addresses; Doh = $Doh })) | Set-Content -Path $script:DnsCustomFile -Encoding UTF8 } catch {}
}

function Load-DnsCustom {
    if (-not (Test-Path $script:DnsCustomFile)) { return }
    try {
        $j = Get-Content -Path $script:DnsCustomFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($j.Addresses -and -not $txtDnsCustom.Text) { $txtDnsCustom.Text = [string]$j.Addresses }
        if ($j.Doh -and -not $txtDnsCustomDoh.Text) { $txtDnsCustomDoh.Text = [string]$j.Doh }
    } catch {}
}

function Test-DohSupported {
    return [bool](Get-Command Add-DnsClientDohServerAddress -ErrorAction SilentlyContinue)
}

# Только физические адаптеры в состоянии Up (VPN/виртуальные не трогаем)
function Get-DnsTargetAdapters {
    try { return @(Get-NetAdapter -Physical -ErrorAction Stop | Where-Object { $_.Status -eq "Up" }) } catch { return @() }
}

function Get-DnsStatusText {
    $adapters = Get-DnsTargetAdapters
    if ($adapters.Count -eq 0) { return "Активные сетевые адаптеры не найдены." }
    $parts = @()
    foreach ($a in $adapters) {
        $addr = @()
        try { $addr = @((Get-DnsClientServerAddress -InterfaceIndex $a.InterfaceIndex -AddressFamily IPv4 -ErrorAction Stop).ServerAddresses) } catch {}
        $list = "—"
        if ($addr.Count -gt 0) { $list = $addr -join ", " }
        $parts += ("{0}: {1}" -f $a.Name, $list)
    }
    $txt = "Сейчас: " + ($parts -join "  |  ")
    if (Test-Path $script:DnsBackupFile) { $txt += "`nПрежние настройки сохранены — кнопка «Вернуть как было» их восстановит." }
    return $txt
}

# ----- Резервная копия прежних настроек (хранится в utils\dns_backup.json) -----
# Дописывается только то, чего в ней ещё нет, поэтому ПЕРВОНАЧАЛЬНЫЕ настройки никогда не перезаписываются,
# даже если пользователь несколько раз менял провайдера или подключал другой адаптер.
function Read-DnsBackup {
    $b = [PSCustomObject]@{ Adapters = @(); Doh = @() }
    if (Test-Path $script:DnsBackupFile) {
        try {
            $j = Get-Content -Path $script:DnsBackupFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($j.PSObject.Properties["Adapters"] -or $j.PSObject.Properties["Doh"]) {
                if ($j.Adapters) { $b.Adapters = @($j.Adapters) }
                if ($j.Doh) { $b.Doh = @($j.Doh) }
            } elseif ($j) {
                $b.Adapters = @($j)   # старый формат: просто список адаптеров
            }
        } catch {}
    }
    return $b
}

function Save-DnsBackup {
    param($Adapters, [string[]]$DohIps)
    $b = Read-DnsBackup

    $knownA = @($b.Adapters | ForEach-Object { [string]$_.Guid })
    $newA = @($b.Adapters)
    foreach ($a in $Adapters) {
        $g = [string]$a.InterfaceGuid
        if ($knownA -contains $g) { continue }
        # Был ли DNS задан вручную? Если значение в реестре пустое — DNS был "автоматически" (DHCP)
        $v4 = ""; $v6 = ""
        try {
            $x = (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$g" -Name NameServer -ErrorAction SilentlyContinue).NameServer
            if ($x) { $v4 = [string]$x }
        } catch {}
        try {
            $x = (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters\Interfaces\$g" -Name NameServer -ErrorAction SilentlyContinue).NameServer
            if ($x) { $v6 = [string]$x }
        } catch {}
        $newA += [PSCustomObject]@{ Alias = [string]$a.Name; Guid = $g; StaticV4 = $v4; StaticV6 = $v6 }
    }

    # DoH: запоминаем, были ли такие записи в Windows до нас (чтобы вернуть как было или удалить свои)
    $knownD = @($b.Doh | ForEach-Object { [string]$_.Ip })
    $newD = @($b.Doh)
    foreach ($ip in $DohIps) {
        if ($knownD -contains $ip) { continue }
        $existing = $null
        try { $existing = Get-DnsClientDohServerAddress -ServerAddress $ip -ErrorAction Stop } catch {}
        if ($existing) {
            $newD += [PSCustomObject]@{ Ip = $ip; Existed = $true; Template = [string]$existing.DohTemplate; AutoUpgrade = [bool]$existing.AutoUpgrade; Fallback = [bool]$existing.AllowFallbackToUdp }
        } else {
            $newD += [PSCustomObject]@{ Ip = $ip; Existed = $false; Template = ""; AutoUpgrade = $false; Fallback = $false }
        }
    }

    try {
        $out = [PSCustomObject]@{ Adapters = @($newA); Doh = @($newD) }
        (ConvertTo-Json -InputObject $out -Depth 4) | Set-Content -Path $script:DnsBackupFile -Encoding UTF8
    } catch {}
}

function Invoke-DnsApply {
    param($Prov, [bool]$UseDoh)
    $adapters = Get-DnsTargetAdapters
    if ($adapters.Count -eq 0) { return "Не найдено активных сетевых адаптеров — подключитесь к сети и повторите." }

    $plain = @($Prov.V4) + @($Prov.V6)
    $useDohNow = ($UseDoh -and $Prov.Doh -and (Test-DohSupported))
    # У некоторых серверов для DoH свои адреса (например, Comss.one: 83.220.169.155 + 195.133.25.16 —
    # так указано в инструкции сайта для Windows 11), у остальных — те же, что и для обычного DNS
    $dohReg = $plain
    if ($Prov.DohIps) { $dohReg = @($Prov.DohIps) }
    $dnsList = $plain
    if ($useDohNow -and $Prov.DnsWithDoh) { $dnsList = @($Prov.DnsWithDoh) }
    $v4only = @($dnsList | Where-Object { $_ -notmatch ':' })
    $dohIps = @()
    if ($useDohNow) { $dohIps = $dohReg }
    Save-DnsBackup -Adapters $adapters -DohIps $dohIps

    # DoH: регистрируем шаблон для адресов провайдера; Windows сам шифрует запросы к ним.
    # Откат на обычный UDP разрешён — если DoH заблокирован, интернет не пропадёт совсем.
    $dohNote = ""
    if ($UseDoh) {
        if (-not (Test-DohSupported)) {
            $dohNote = " (DoH в этой версии Windows недоступен — использован обычный DNS)"
        } elseif (-not $Prov.Doh) {
            $dohNote = " (шаблон DoH не указан — использован обычный DNS)"
        } else {
            foreach ($ip in $dohReg) {
                try {
                    Add-DnsClientDohServerAddress -ServerAddress $ip -DohTemplate $Prov.Doh -AllowFallbackToUdp $true -AutoUpgrade $true -ErrorAction Stop | Out-Null
                } catch {
                    try { Set-DnsClientDohServerAddress -ServerAddress $ip -DohTemplate $Prov.Doh -AllowFallbackToUdp $true -AutoUpgrade $true -ErrorAction Stop | Out-Null } catch {}
                }
            }
            $dohNote = " + DoH"
        }
    }

    $ok = 0
    $errs = @()
    foreach ($a in $adapters) {
        $done = $false
        # сначала IPv4+IPv6, если у адаптера IPv6 выключен — только IPv4
        try { Set-DnsClientServerAddress -InterfaceIndex $a.InterfaceIndex -ServerAddresses $dnsList -ErrorAction Stop; $done = $true } catch {}
        if (-not $done -and $v4only.Count -gt 0) {
            try { Set-DnsClientServerAddress -InterfaceIndex $a.InterfaceIndex -ServerAddresses $v4only -ErrorAction Stop; $done = $true } catch { $errs += ("{0}: {1}" -f $a.Name, $_.Exception.Message) }
        } elseif (-not $done) {
            $errs += ("{0}: не удалось установить адреса" -f $a.Name)
        }
        if ($done) { $ok++ }
    }
    # Кеш DNS намеренно НЕ сбрасываем — меняем только серверы.

    if ($ok -eq 0) { return "Не удалось сменить DNS. " + ($errs -join "; ") }
    $msg = "Готово: DNS {0}{1} установлен на адаптерах: {2}." -f $Prov.Name, $dohNote, $ok
    if ($errs.Count -gt 0) { $msg += " Не удалось: " + ($errs -join "; ") }
    return $msg
}

function Invoke-DnsRestore {
    $b = Read-DnsBackup
    $allPhysical = @()
    try { $allPhysical = @(Get-NetAdapter -Physical -ErrorAction Stop) } catch {}
    $ok = 0; $auto = 0; $manual = 0

    if ($b.Adapters.Count -eq 0) {
        # Резервной копии нет (файл удалён) — безопасный вариант: "автоматически" на активных адаптерах
        foreach ($a in (Get-DnsTargetAdapters)) {
            try { Set-DnsClientServerAddress -InterfaceIndex $a.InterfaceIndex -ResetServerAddresses -ErrorAction Stop; $ok++; $auto++ } catch {}
        }
    } else {
        # Возвращаем адаптеры по сохранённому GUID, даже если сейчас активен уже другой (Wi-Fi <-> Ethernet)
        foreach ($saved in $b.Adapters) {
            $a = $allPhysical | Where-Object { [string]$_.InterfaceGuid -eq [string]$saved.Guid } | Select-Object -First 1
            if (-not $a) { continue }
            $addrs = @()
            foreach ($s in @($saved.StaticV4, $saved.StaticV6)) {
                if ($s) { $addrs += @(([string]$s) -split '[,\s]+' | Where-Object { $_ }) }
            }
            try {
                if ($addrs.Count -gt 0) {
                    Set-DnsClientServerAddress -InterfaceIndex $a.InterfaceIndex -ServerAddresses $addrs -ErrorAction Stop
                    $manual++
                } else {
                    # DNS был "автоматически" — просто включаем автоматический режим обратно
                    Set-DnsClientServerAddress -InterfaceIndex $a.InterfaceIndex -ResetServerAddresses -ErrorAction Stop
                    $auto++
                }
                $ok++
            } catch {}
        }
    }

    # DoH: записи, которых раньше не было, удаляем; те, что были, возвращаем к прежним параметрам
    if (Test-DohSupported) {
        foreach ($d in $b.Doh) {
            try {
                if ($d.Existed) {
                    Set-DnsClientDohServerAddress -ServerAddress $d.Ip -DohTemplate $d.Template -AutoUpgrade ([bool]$d.AutoUpgrade) -AllowFallbackToUdp ([bool]$d.Fallback) -ErrorAction Stop | Out-Null
                } else {
                    Remove-DnsClientDohServerAddress -ServerAddress $d.Ip -Confirm:$false -ErrorAction Stop
                }
            } catch {}
        }
    }
    # Кеш DNS намеренно НЕ сбрасываем.

    if (Test-Path $script:DnsBackupFile) { Remove-Item $script:DnsBackupFile -Force -ErrorAction SilentlyContinue }
    if ($ok -eq 0) { return "Не удалось вернуть DNS." }
    return "DNS возвращён как было: автоматически — {0}, прежний ручной DNS — {1}." -f $auto, $manual
}

$cmbDnsProvider.Add_SelectionChanged({
    try {
        if ($cmbDnsProvider.SelectedIndex -ge $script:DnsProviders.Count) {
            Load-DnsCustom
            $panelDnsCustom.Visibility = "Visible"
            $txtDnsInfo.Text = ""
        } else {
            $panelDnsCustom.Visibility = "Collapsed"
            $txtDnsInfo.Text = Get-DnsProviderInfoText -Index $cmbDnsProvider.SelectedIndex
        }
    } catch {}
})

function Update-DnsPanel {
    try {
        $txtDnsInfo.Text = Get-DnsProviderInfoText -Index $cmbDnsProvider.SelectedIndex
        if (-not (Test-DohSupported)) {
            $chkDnsDoh.IsChecked = $false
            $chkDnsDoh.IsEnabled = $false
            $chkDnsDoh.Content = "Шифровать запросы (DoH) — недоступно в этой версии Windows"
        }
        $txtDnsStatus.Text = Get-DnsStatusText
    } catch {}
}

$btnApplyDns.Add_Click({
    try {
        $btnApplyDns.IsEnabled = $false
        $btnResetDns.IsEnabled = $false
        $txtDnsStatus.Text = "Применяю..."
        Force-Render
        $idx = $cmbDnsProvider.SelectedIndex
        if ($idx -lt 0) { $idx = 0 }
        if ($idx -ge $script:DnsProviders.Count) {
            # «Свой DNS…»: проверяем введённое, и только потом применяем
            $prov = Get-DnsCustomProvider -AddressText $txtDnsCustom.Text -DohText $txtDnsCustomDoh.Text
            if ($prov.Error) { $txtDnsStatus.Text = [string]$prov.Error; return }
            Save-DnsCustom -Addresses $txtDnsCustom.Text.Trim() -Doh $txtDnsCustomDoh.Text.Trim()
        } else {
            $prov = $script:DnsProviders[$idx]
        }
        $res = Invoke-DnsApply -Prov $prov -UseDoh ([bool]$chkDnsDoh.IsChecked)
        $txtDnsStatus.Text = $res + "`n" + (Get-DnsStatusText)
        Update-Log -Lines @("DNS: $res")
    } catch {
        $txtDnsStatus.Text = "Ошибка: $($_.Exception.Message)"
    } finally {
        $btnApplyDns.IsEnabled = $true
        $btnResetDns.IsEnabled = $true
    }
})

$btnResetDns.Add_Click({
    try {
        $btnApplyDns.IsEnabled = $false
        $btnResetDns.IsEnabled = $false
        $txtDnsStatus.Text = "Возвращаю..."
        Force-Render
        $res = Invoke-DnsRestore
        $txtDnsStatus.Text = $res + "`n" + (Get-DnsStatusText)
        Update-Log -Lines @("DNS: $res")
    } catch {
        $txtDnsStatus.Text = "Ошибка: $($_.Exception.Message)"
    } finally {
        $btnApplyDns.IsEnabled = $true
        $btnResetDns.IsEnabled = $true
    }
})

# ---------------- Защита папки программы ----------------
# Закрывает папку zapret от обычных пользователей Windows и скрывает её, но оставляет доступ к спискам (lists)
# и плейлисту (assets\playlist). Это защита от случайного захода, а не от опытного пользователя-администратора:
# Проводник предложит ему "Продолжить" и откроет папку после подтверждения UAC.
# До вложенных папок можно добраться по полному пути, даже если родительскую открыть нельзя:
# право "Обход перекрёстной проверки" включено у всех пользователей по умолчанию.
function Lock-ZapretFolder {
    param([string]$Dir)
    if (-not (Test-Path -LiteralPath $Dir)) { return "Папка программы не найдена." }
    $open = @((Join-Path $Dir "lists"), (Join-Path $Dir "assets\playlist"))
    foreach ($d in $open) {
        if (-not (Test-Path -LiteralPath $d)) { try { New-Item -ItemType Directory -Path $d -Force | Out-Null } catch {} }
    }
    # 1) сначала полный доступ системе и администраторам — пока наследование включено, доступ не пропадает ни на миг
    $out = & icacls.exe $Dir /grant:r "*S-1-5-18:(OI)(CI)F" "*S-1-5-32-544:(OI)(CI)F" 2>&1
    if ($LASTEXITCODE -ne 0) { return "Не удалось изменить права папки (нужен запуск от имени администратора). $($out -join ' ')" }
    # 2) убираем унаследованные права, в том числе у группы "Пользователи"
    $out = & icacls.exe $Dir /inheritance:r 2>&1
    if ($LASTEXITCODE -ne 0) { return "Не удалось отключить наследование прав. $($out -join ' ')" }
    # 3) обычным пользователям оставляем только lists и плейлист (чтение и запись)
    $failed = @()
    foreach ($d in $open) {
        $out = & icacls.exe $d /grant "*S-1-5-32-545:(OI)(CI)M" 2>&1
        if ($LASTEXITCODE -ne 0) { $failed += $d }
    }
    # 4) скрываем папку (атрибуты "Скрытый" + "Системный")
    try {
        $it = Get-Item -LiteralPath $Dir -Force
        $it.Attributes = [System.IO.FileAttributes]([int]$it.Attributes -bor 6)
    } catch {}
    if ($failed.Count -gt 0) { return "Папка закрыта, но не удалось открыть доступ к: " + ($failed -join ", ") }
    return "Готово: папка скрыта и закрыта от обычных пользователей. Доступны: lists и плейлист."
}

function Test-ZapretFolderLocked {
    param([string]$Dir)
    try {
        $acl = Get-Acl -LiteralPath $Dir -ErrorAction Stop
        if (-not $acl.AreAccessRulesProtected) { return $false }
        $broad = @("S-1-5-32-545", "S-1-1-0", "S-1-5-11")   # Пользователи, Все, Прошедшие проверку
        $rules = @($acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]))
        foreach ($r in $rules) {
            if (($r.AccessControlType -eq "Allow") -and ($broad -contains $r.IdentityReference.Value)) { return $false }
        }
        return $true
    } catch { return $false }
}

function Unlock-ZapretFolder {
    param([string]$Dir)
    if (-not (Test-Path -LiteralPath $Dir)) { return "Папка программы не найдена." }
    try {
        $it = Get-Item -LiteralPath $Dir -Force
        $it.Attributes = [System.IO.FileAttributes]([int]$it.Attributes -band (-bnot 6))
    } catch {}
    $out = & icacls.exe $Dir /inheritance:e 2>&1
    if ($LASTEXITCODE -ne 0) { return "Не удалось вернуть наследование прав. $($out -join ' ')" }
    # /reset возвращает стандартные унаследованные права для папки и всего внутри (в т.ч. lists и плейлиста)
    $out = & icacls.exe $Dir /reset /T /C 2>&1
    if (Test-ZapretFolderLocked -Dir $Dir) { return "Не удалось полностью вернуть права. $($out -join ' ')" }
    return "Готово: папка снова обычная — видна и доступна всем пользователям."
}

function Update-LockPanel {
    try {
        if (Test-ZapretFolderLocked -Dir $ZapretDir) {
            $txtLockStatus.Text = "Сейчас: папка скрыта и закрыта от обычных пользователей (доступны lists и плейлист)."
        } else {
            $txtLockStatus.Text = "Сейчас: папка открыта — её видят и открывают все пользователи."
        }
    } catch {}
}

# Саму папку программы после блокировки не открыть, поэтому у lists и плейлиста есть свои кнопки
function Open-FolderInExplorer {
    param([string]$Path)
    try {
        if (-not (Test-Path -LiteralPath $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
        Start-Process explorer.exe -ArgumentList "`"$Path`""
    } catch {}
}

$btnOpenListsFolder.Add_Click({ Open-FolderInExplorer -Path $ListsDir })
$btnOpenPlaylistFolderSettings.Add_Click({ Open-FolderInExplorer -Path (Join-Path $ZapretDir "assets\playlist") })

$btnLockFolder.Add_Click({
    try {
        $btnLockFolder.IsEnabled = $false
        $btnUnlockFolder.IsEnabled = $false
        $txtLockStatus.Text = "Применяю..."
        Force-Render
        $res = Lock-ZapretFolder -Dir $ZapretDir
        $txtLockStatus.Text = $res
        Update-Log -Lines @("Защита папки: $res")
    } catch {
        $txtLockStatus.Text = "Ошибка: $($_.Exception.Message)"
    } finally {
        $btnLockFolder.IsEnabled = $true
        $btnUnlockFolder.IsEnabled = $true
    }
})

$btnUnlockFolder.Add_Click({
    try {
        $btnLockFolder.IsEnabled = $false
        $btnUnlockFolder.IsEnabled = $false
        $txtLockStatus.Text = "Применяю..."
        Force-Render
        $res = Unlock-ZapretFolder -Dir $ZapretDir
        $txtLockStatus.Text = $res
        Update-Log -Lines @("Защита папки: $res")
    } catch {
        $txtLockStatus.Text = "Ошибка: $($_.Exception.Message)"
    } finally {
        $btnLockFolder.IsEnabled = $true
        $btnUnlockFolder.IsEnabled = $true
    }
})

$btnIpsetToggle.Add_Click({ Update-Log -Clear -Lines (Invoke-IpsetToggle) })
$btnToggleAutoCheck.Add_Click({
    $newState = Invoke-ToggleCheckUpdates
    Update-Log -Clear -Lines @("Автопроверка обновлений: $newState")
})

$btnUpdateIpset.Add_Click({
    Update-Log -Clear -Lines @("Загрузка списка IP...")
    Force-Render
    Update-Log -Lines (Invoke-IpsetUpdate)
})
$btnUpdateHosts.Add_Click({
    Update-Log -Clear -Lines @("Проверка hosts-файла...")
    Force-Render
    Update-Log -Lines (Invoke-HostsUpdate)
})
$btnCheckUpdates.Add_Click({
    Update-Log -Clear -Lines @("Проверка обновлений...")
    Force-Render
    Update-Log -Lines (Invoke-CheckForUpdates)
})

$btnRemoveConflicts.Add_Click({
    $r = [System.Windows.MessageBox]::Show("Удалить конфликтующие службы (GoodbyeDPI, WinDivert и т.д.)?", "Подтверждение", [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Warning)
    if ($r -eq [System.Windows.MessageBoxResult]::Yes) {
        Update-Log -Clear -Lines (Invoke-RemoveConflicts)
    }
})
$btnRemoveService.Add_Click({
    $r = [System.Windows.MessageBox]::Show("Удалить службу zapret (автозапуск)?", "Подтверждение", [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Warning)
    if ($r -eq [System.Windows.MessageBoxResult]::Yes) {
        Stop-Zapret
        Save-ActiveStrategy -Name $null
        Update-Log -Clear -Lines @("Служба zapret удалена.")
        Refresh-StatusUI
    }
})

$btnAbout.Add_Click({
    [System.Windows.MessageBox]::Show("Zapret GUI`nОболочка для zapret-discord-youtube`nhttps://github.com/Flowseal/zapret-discord-youtube", "О программе") | Out-Null
})

# ---------------------------------------------------------------
# Аватарка пользователя (правый верхний угол)
# ---------------------------------------------------------------
$script:AvatarConfigFile = Join-Path $UtilsDir "gui_avatar.txt"
$script:HasAvatar = $false

function Set-AvatarImage {
    param([string]$ImagePath)
    try {
        $bitmap = New-Object System.Windows.Media.Imaging.BitmapImage
        $bitmap.BeginInit()
        $bitmap.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $bitmap.CreateOptions = [System.Windows.Media.Imaging.BitmapCreateOptions]::IgnoreImageCache
        $bitmap.UriSource = New-Object System.Uri($ImagePath, [System.UriKind]::Absolute)
        $bitmap.EndInit()
        $bitmap.Freeze()
        $brush = New-Object System.Windows.Media.ImageBrush($bitmap)
        $brush.Stretch = "UniformToFill"
        $avatarBorder.Background = $brush
        if ($avatarPlaceholder) { $avatarPlaceholder.Visibility = "Collapsed" }
        $script:HasAvatar = $true
    } catch {
        [System.Windows.MessageBox]::Show("Не удалось загрузить изображение: $($_.Exception.Message)", "Zapret") | Out-Null
    }
}

function Import-SavedAvatar {
    if (Test-Path $script:AvatarConfigFile) {
        $savedPath = (Get-Content $script:AvatarConfigFile -Raw -ErrorAction SilentlyContinue)
        if ($savedPath) { $savedPath = $savedPath.Trim() }
        if ($savedPath -and (Test-Path $savedPath)) {
            Set-AvatarImage -ImagePath $savedPath
        }
    }
}

function Remove-Avatar {
    try {
        if (Test-Path $script:AvatarConfigFile) {
            $savedPath = (Get-Content $script:AvatarConfigFile -Raw -ErrorAction SilentlyContinue)
            if ($savedPath) { $savedPath = $savedPath.Trim() }
            if ($savedPath -and (Test-Path $savedPath)) { Remove-Item $savedPath -Force -ErrorAction SilentlyContinue }
            Remove-Item $script:AvatarConfigFile -Force -ErrorAction SilentlyContinue
        }
        $avatarBorder.Background = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#1B1B27")
        if ($avatarPlaceholder) { $avatarPlaceholder.Visibility = "Visible" }
        $script:HasAvatar = $false
    } catch {}
}

function Show-DomainFinderDialog {
    [xml]$dfXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Определить домены" Width="480" Height="680" MinHeight="480"
        WindowStartupLocation="CenterOwner" ResizeMode="CanResizeWithGrip"
        Background="#0B0B12" FontFamily="Segoe UI">
    <Grid Margin="20">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
        </Grid.RowDefinitions>

        <TextBlock Grid.Row="0" Text="Определить домены приложения или сайта" Foreground="White" FontSize="16" FontWeight="Bold" Margin="0,0,0,4"/>

        <TextBlock Grid.Row="1" Text="СПОСОБ 1: САЙТ ПО ССЫЛКЕ (Chrome/Edge)" Foreground="Gray" FontSize="11" Margin="0,10,0,6"/>
        <StackPanel Grid.Row="2" Orientation="Horizontal" Margin="0,0,0,4">
            <TextBox x:Name="txtDfUrl" Width="300" Height="30" Background="#1B1B27" Foreground="White" BorderThickness="0" Padding="8,4" Text="" ToolTip="Вставьте адрес сайта, например example.com"/>
            <Button x:Name="btnDfUrlGo" Content="Найти" Height="30" Margin="8,0,0,0" Foreground="White" BorderThickness="0" Padding="14,0" Cursor="Hand">
                <Button.Background>
                    <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                        <GradientStop Color="#8E44E0" Offset="0"/>
                        <GradientStop Color="#E63950" Offset="1"/>
                    </LinearGradientBrush>
                </Button.Background>
            </Button>
        </StackPanel>
        <TextBlock Grid.Row="3" Text="Программа откроет сайт в отдельном окне Chrome/Edge с чистым временным профилем — ваш обычный браузер и вкладки не трогаются. QUIC (HTTP/3) отключается на время проверки, чтобы соединение шло по обычному TCP, который zapret умеет обходить — иначе в чистом профиле сайт может зависнуть. Через 15 секунд окно само закроется." Foreground="#5E5E6B" FontSize="10.5" TextWrapping="Wrap" Margin="0,0,0,14"/>

        <TextBlock Grid.Row="4" Text="СПОСОБ 2: ПО ЗАПУЩЕННОМУ ПРОЦЕССУ (для программ и игр, не сайтов)" Foreground="Gray" FontSize="11" Margin="0,0,0,6"/>
        <StackPanel Grid.Row="5" Orientation="Horizontal" Margin="0,0,0,4">
            <ComboBox x:Name="cmbDfProcess" Width="300" Height="30" Background="#1B1B27" Foreground="Black"/>
            <Button x:Name="btnDfRefresh" Content="Обновить" Height="30" Margin="8,0,0,0" Background="#1B1B27" Foreground="White" BorderThickness="0" Padding="10,0" Cursor="Hand"/>
        </StackPanel>
        <TextBlock Grid.Row="6" Text="Вместе со списком соединений в фоне идёт захват сетевого трафика (pktmon) — он нужен, чтобы находить домены даже там, где они видны только в самом трафике, а не в списке TCP-соединений (например, в играх со Steam-сетевым кодом, использующим UDP)." Foreground="#5E5E6B" FontSize="10.5" TextWrapping="Wrap" Margin="0,0,0,10"/>

        <StackPanel Grid.Row="7" Orientation="Horizontal" Margin="0,0,0,10">
            <Button x:Name="btnDfStart" Content="Начать отслеживание" Height="34" Foreground="White" BorderThickness="0" Padding="14,0" Cursor="Hand">
                <Button.Background>
                    <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                        <GradientStop Color="#8E44E0" Offset="0"/>
                        <GradientStop Color="#E63950" Offset="1"/>
                    </LinearGradientBrush>
                </Button.Background>
            </Button>
            <Button x:Name="btnDfStop" Content="Остановить" Height="34" Margin="10,0,0,0" Background="#1B1B27" Foreground="White" BorderThickness="0" Padding="14,0" Cursor="Hand" IsEnabled="False"/>
        </StackPanel>

        <StackPanel Grid.Row="8" Orientation="Horizontal">
            <TextBlock x:Name="dfStatus" Text="Ожидание." Foreground="#8A8A99" FontSize="12" VerticalAlignment="Center"/>
            <Button x:Name="btnDfToggleIp" Content="Показать IP" Height="24" Margin="10,0,0,0" Background="#1B1B27" Foreground="#8A8A99" BorderThickness="0" FontSize="10.5" Padding="10,0" Cursor="Hand"/>
        </StackPanel>

        <Border Grid.Row="9" Background="#12121B" CornerRadius="8" Padding="4" Margin="0,10,0,0">
            <ScrollViewer VerticalScrollBarVisibility="Auto">
                <ListBox x:Name="lstDfDomains" Background="Transparent" BorderThickness="0" Foreground="#D8D8E0" FontSize="12.5"/>
            </ScrollViewer>
        </Border>
    </Grid>
</Window>
"@

    $readerDf = New-Object System.Xml.XmlNodeReader $dfXaml
    $dfWindow = [Windows.Markup.XamlReader]::Load($readerDf)
    try { $dfWindow.Owner = $window } catch {}

    $txtDfUrl = $dfWindow.FindName("txtDfUrl")
    $btnDfUrlGo = $dfWindow.FindName("btnDfUrlGo")
    $cmbDfProcess = $dfWindow.FindName("cmbDfProcess")
    $btnDfRefresh = $dfWindow.FindName("btnDfRefresh")
    $btnDfStart = $dfWindow.FindName("btnDfStart")
    $btnDfStop = $dfWindow.FindName("btnDfStop")
    $dfStatus = $dfWindow.FindName("dfStatus")
    $lstDfDomains = $dfWindow.FindName("lstDfDomains")
    $btnDfToggleIp = $dfWindow.FindName("btnDfToggleIp")

    # Кеш иконок по пути к exe, чтобы не извлекать одну и ту же иконку заново при каждом обновлении списка
    $script:DfIconCache = @{}
    function Get-DfProcessIconSource {
        param([string]$ExePath)
        if (-not $ExePath) { return $null }
        if ($script:DfIconCache.ContainsKey($ExePath)) { return $script:DfIconCache[$ExePath] }
        $src = $null
        try {
            $icon = [System.Drawing.Icon]::ExtractAssociatedIcon($ExePath)
            if ($icon) {
                $src = [System.Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon(
                    $icon.Handle,
                    [System.Windows.Int32Rect]::Empty,
                    [System.Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions()
                )
                $src.Freeze()
                $icon.Dispose()
            }
        } catch {}
        $script:DfIconCache[$ExePath] = $src
        return $src
    }

    function Update-DfProcessList {
        $cmbDfProcess.Items.Clear()
        try {
            $pidsWithConns = (Get-NetTCPConnection -ErrorAction SilentlyContinue | Select-Object -ExpandProperty OwningProcess -Unique)
            $procs = Get-Process -ErrorAction SilentlyContinue | Where-Object { $pidsWithConns -contains $_.Id -and $_.ProcessName -notin @("Idle","System") } | Sort-Object ProcessName
            foreach ($p in $procs) {
                $exePath = $null
                try { $exePath = $p.MainModule.FileName } catch {}
                $iconSrc = if ($exePath) { Get-DfProcessIconSource -ExePath $exePath } else { $null }

                $row = New-Object System.Windows.Controls.StackPanel
                $row.Orientation = [System.Windows.Controls.Orientation]::Horizontal
                if ($iconSrc) {
                    $img = New-Object System.Windows.Controls.Image
                    $img.Source = $iconSrc
                    $img.Width = 16
                    $img.Height = 16
                    $img.Margin = "0,0,8,0"
                    [void]$row.Children.Add($img)
                } else {
                    $ph = New-Object System.Windows.Controls.Border
                    $ph.Width = 16
                    $ph.Height = 16
                    $ph.Margin = "0,0,8,0"
                    [void]$row.Children.Add($ph)
                }
                $txt = New-Object System.Windows.Controls.TextBlock
                $txt.Text = "$($p.ProcessName)  (PID $($p.Id))"
                $txt.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
                [void]$row.Children.Add($txt)

                $item = New-Object System.Windows.Controls.ComboBoxItem
                $item.Content = $row
                $item.Tag = $p.Id
                [void]$cmbDfProcess.Items.Add($item)
            }
            if ($cmbDfProcess.Items.Count -gt 0) { $cmbDfProcess.SelectedIndex = 0 }
        } catch {
            $dfStatus.Text = "Не удалось получить список процессов: $($_.Exception.Message)"
        }
    }
    Update-DfProcessList
    $btnDfRefresh.Add_Click({ Update-DfProcessList })

    $script:DfNamed = @()
    $script:DfUnnamed = @()
    $script:DfShowIp = $false

    function Set-DfControlsEnabled {
        param([bool]$Enabled)
        $btnDfStart.IsEnabled = $Enabled
        $cmbDfProcess.IsEnabled = $Enabled
        $btnDfUrlGo.IsEnabled = $Enabled
        $txtDfUrl.IsEnabled = $Enabled
    }

    function Render-DfList {
        $lstDfDomains.Items.Clear()
        foreach ($name in $script:DfNamed) {
            if ($script:DfShowIp -and $name.Ip) { [void]$lstDfDomains.Items.Add("$($name.Domain)   ($($name.Ip))") }
            else { [void]$lstDfDomains.Items.Add($name.Domain) }
        }
        if ($script:DfShowIp -and $script:DfUnnamed.Count -gt 0) {
            [void]$lstDfDomains.Items.Add("──────── IP без определённого имени ────────")
            foreach ($ip in $script:DfUnnamed) { [void]$lstDfDomains.Items.Add($ip) }
        }
    }

    $btnDfToggleIp.Add_Click({
        $script:DfShowIp = -not $script:DfShowIp
        $btnDfToggleIp.Content = if ($script:DfShowIp) { "Скрыть IP" } else { "Показать IP" }
        Render-DfList
    })

    # --- Способ 1: сайт по ссылке, отдельный временный профиль, QUIC отключён ---
    function Get-DfBrowserExe {
        $candidates = @(
            (Join-Path $env:ProgramFiles "Google\Chrome\Application\chrome.exe"),
            (Join-Path ${env:ProgramFiles(x86)} "Google\Chrome\Application\chrome.exe"),
            (Join-Path $env:LOCALAPPDATA "Google\Chrome\Application\chrome.exe"),
            (Join-Path $env:ProgramFiles "Microsoft\Edge\Application\msedge.exe"),
            (Join-Path ${env:ProgramFiles(x86)} "Microsoft\Edge\Application\msedge.exe")
        )
        foreach ($c in $candidates) { if ($c -and (Test-Path $c)) { return $c } }
        return $null
    }

    $script:DfCdpJob = $null
    $cdpTimer = New-Object System.Windows.Threading.DispatcherTimer
    $cdpTimer.Interval = [TimeSpan]::FromMilliseconds(400)
    $cdpTimer.Add_Tick({
        if (-not $script:DfCdpJob) { $cdpTimer.Stop(); return }
        if ($script:DfCdpJob.State -in @('Completed','Failed','Stopped')) {
            $cdpTimer.Stop()
            $out = @(Receive-Job -Job $script:DfCdpJob -ErrorAction SilentlyContinue)
            Remove-Job -Job $script:DfCdpJob -Force -ErrorAction SilentlyContinue
            $script:DfCdpJob = $null
            Set-DfControlsEnabled -Enabled $true

            if ($out.Count -eq 1 -and $out[0] -is [string] -and $out[0].StartsWith("ERROR:")) {
                $dfStatus.Text = $out[0].Substring(6)
                return
            }
            $script:DfNamed = @($out | Where-Object { $_ } | Sort-Object -Unique | ForEach-Object { [PSCustomObject]@{ Domain = $_; Ip = "" } })
            $script:DfUnnamed = @()
            Render-DfList
            $dfStatus.Text = "Готово. Найдено доменов: $($script:DfNamed.Count)."
        }
    })

    $btnDfUrlGo.Add_Click({
        $url = $txtDfUrl.Text.Trim()
        if (-not $url) { $dfStatus.Text = "Введите ссылку на сайт."; return }
        if ($url -notmatch '^https?://') { $url = "https://$url" }

        $browserExe = Get-DfBrowserExe
        if (-not $browserExe) {
            $dfStatus.Text = "Не найден Chrome или Edge — этот способ работает только с ними."
            return
        }

        $lstDfDomains.Items.Clear()
        Set-DfControlsEnabled -Enabled $false
        $dfStatus.Text = "Открываю отдельное окно браузера и слушаю запросы (около 15 сек)..."

        $script:DfCdpJob = Start-Job -ScriptBlock {
            param($BrowserExe, $Url, $Seconds)
            $port = Get-Random -Minimum 9300 -Maximum 9999
            $profileDir = Join-Path $env:TEMP ("zapret_df_profile_{0}" -f $port)
            $domains = New-Object System.Collections.Generic.HashSet[string]
            $proc = $null
            try {
                # --disable-quic: в чистом профиле браузер может попытаться пойти по QUIC
                # (HTTP/3, поверх UDP) — zapret обходит блокировки на уровне TCP, и QUIC-соединение
                # в обход этого механизма может просто зависнуть. Отключаем на время проверки.
                $proc = Start-Process -FilePath $BrowserExe -ArgumentList @(
                    "--remote-debugging-port=$port",
                    "--user-data-dir=$profileDir",
                    "--no-first-run",
                    "--no-default-browser-check",
                    "--disable-quic",
                    "--disable-sync",
                    "--disable-features=Translate,MediaRouter",
                    $Url
                ) -PassThru

                $pg = $null
                for ($i = 0; $i -lt 25 -and -not $pg; $i++) {
                    Start-Sleep -Milliseconds 300
                    try {
                        $list = Invoke-RestMethod -Uri "http://127.0.0.1:$port/json" -TimeoutSec 2 -ErrorAction Stop
                        $pg = $list | Where-Object { $_.type -eq "page" -and $_.webSocketDebuggerUrl } | Select-Object -First 1
                    } catch {}
                }
                if (-not $pg) { return "ERROR:Не удалось подключиться к браузеру (отладочный порт не ответил)." }

                $ws = New-Object System.Net.WebSockets.ClientWebSocket
                $cts = New-Object System.Threading.CancellationTokenSource
                $ws.ConnectAsync([Uri]$pg.webSocketDebuggerUrl, $cts.Token).GetAwaiter().GetResult() | Out-Null

                $enableMsg = [System.Text.Encoding]::UTF8.GetBytes('{"id":1,"method":"Network.enable"}')
                $seg = New-Object System.ArraySegment[byte] (,$enableMsg)
                $ws.SendAsync($seg, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $cts.Token).GetAwaiter().GetResult() | Out-Null

                $deadline = (Get-Date).AddSeconds($Seconds)
                $buffer = New-Object byte[] 131072
                $msgBuilder = New-Object System.Text.StringBuilder
                $totalMsgCount = 0
                while ((Get-Date) -lt $deadline) {
                    $recvCts = New-Object System.Threading.CancellationTokenSource
                    $recvCts.CancelAfter(800)
                    try {
                        $segRecv = New-Object System.ArraySegment[byte] (,$buffer)
                        $result = $ws.ReceiveAsync($segRecv, $recvCts.Token).GetAwaiter().GetResult()
                        if ($result.Count -gt 0) {
                            [void]$msgBuilder.Append([System.Text.Encoding]::UTF8.GetString($buffer, 0, $result.Count))
                        }
                        if (-not $result.EndOfMessage) { continue }
                        $msg = $msgBuilder.ToString()
                        $msgBuilder.Clear() | Out-Null
                        if (-not $msg) { continue }
                        $totalMsgCount++
                        if ($msg -match '"method"\s*:\s*"Network\.requestWillBeSent"') {
                            $m = [regex]::Match($msg, '"url"\s*:\s*"(https?://[^"\\]+)')
                            if ($m.Success) {
                                $u = $m.Groups[1].Value
                                $hm = [regex]::Match($u, '^https?://([^/:\\]+)')
                                if ($hm.Success) { [void]$domains.Add($hm.Groups[1].Value.ToLower()) }
                            }
                        }
                    } catch {}
                }
                try { $ws.Dispose() } catch {}
            } catch {
                return "ERROR:Ошибка при захвате: $($_.Exception.Message)"
            } finally {
                if ($proc) { try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch {} }
                try { Get-Process | Where-Object { $_.Path -eq $BrowserExe -and $_.CommandLine -like "*$profileDir*" } | Stop-Process -Force -ErrorAction SilentlyContinue } catch {}
                Start-Sleep -Milliseconds 500
                try { Remove-Item $profileDir -Recurse -Force -ErrorAction SilentlyContinue } catch {}
            }

            if ($domains.Count -eq 0) {
                if ($totalMsgCount -eq 0) {
                    return "ERROR:Не получено ни одного события от браузера — возможно, антивирус/файрвол блокирует локальное соединение с отладочным портом."
                }
                return "ERROR:Запросов не поймано (сообщений получено: $totalMsgCount). Попробуйте ещё раз."
            }
            return @($domains)
        } -ArgumentList $browserExe, $url, 15

        $cdpTimer.Start()
    })

    # --- Способ 2: по запущенному процессу (для обычных программ, не сайтов) ---
    function Get-DfDnsSnapshot {
        $map = @{}
        try {
            foreach ($e in (Get-DnsClientCache -ErrorAction SilentlyContinue)) {
                if ($e.Name -and $e.Data -and -not $map.ContainsKey([string]$e.Data)) { $map[[string]$e.Data] = $e.Name }
            }
        } catch {}
        return $map
    }

    # pktmon (встроен в Windows, права администратора уже есть) ловит реальный трафик — это
    # нужно для игр и программ, где нужный домен виден только в TLS-рукопожатии (SNI) или в
    # UDP-пакетах (Steam-игры, например), а не через список TCP-соединений или DNS-кеш.
    # Windows в принципе не даёт узнать удалённый адрес UDP-сокета штатными средствами
    # (netstat/Get-NetUDPEndpoint всегда показывают "*:*" для UDP) — это не ограничение
    # нашего кода, а системное, поэтому без захвата пакетов здесь не обойтись.
    $script:DfPktmonPath = $null
    function Start-DfPktmonCapture {
        $script:DfPktmonPath = Join-Path $env:TEMP ("zapret_df_proc_capture_{0}.etl" -f (Get-Random))
        try { & pktmon start --capture --pkt-size 0 --file-name $script:DfPktmonPath 2>$null | Out-Null } catch { $script:DfPktmonPath = $null }
    }
    function Stop-DfPktmonCapture {
        try { & pktmon stop 2>$null | Out-Null } catch {}
        if (-not $script:DfPktmonPath -or -not (Test-Path $script:DfPktmonPath)) { return @() }
        $domains = @()
        try {
            $bytes = [System.IO.File]::ReadAllBytes($script:DfPktmonPath)
            $text = [System.Text.Encoding]::GetEncoding("ISO-8859-1").GetString($bytes)
            $rx = [regex]'(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.){1,8}[A-Za-z]{2,24}'
            $domains = $rx.Matches($text) | ForEach-Object { $_.Value.ToLower() } | Where-Object { $_ -notmatch '\.\.' } | Sort-Object -Unique
        } catch {}
        Remove-Item $script:DfPktmonPath -Force -ErrorAction SilentlyContinue
        $script:DfPktmonPath = $null
        return @($domains)
    }

    function Show-DfProcessResults {
        param([hashtable]$DnsMap, [string[]]$PktmonDomains)
        $named = New-Object System.Collections.ArrayList
        $unnamed = New-Object System.Collections.ArrayList
        foreach ($ip in $collectedIPs) {
            if ($DnsMap.ContainsKey($ip)) {
                [void]$named.Add([PSCustomObject]@{ Domain = $DnsMap[$ip]; Ip = $ip })
            } else {
                [void]$unnamed.Add($ip)
            }
        }
        $namedDomains = @($named | ForEach-Object { $_.Domain })
        foreach ($d in $PktmonDomains) {
            if ($d -and ($namedDomains -notcontains $d)) {
                [void]$named.Add([PSCustomObject]@{ Domain = $d; Ip = "" })
                $namedDomains += $d
            }
        }
        if ($named.Count -eq 0 -and $unnamed.Count -eq 0) {
            $lstDfDomains.Items.Clear()
            $dfStatus.Text = "Ничего не найдено. Убедитесь, что приложение успело обменяться данными во время отслеживания."
            return
        }
        $script:DfNamed = @($named | Sort-Object Domain)
        $script:DfUnnamed = @($unnamed | Sort-Object)
        Render-DfList
        $dfStatus.Text = "Готово. Доменов: $($script:DfNamed.Count), только IP: $($script:DfUnnamed.Count). Возможны единичные не-доменные совпадения из общего трафика ПК — это нормально для захвата пакетов."
    }

    $collectedIPs = [System.Collections.Generic.HashSet[string]]::new()
    $trackTimer = New-Object System.Windows.Threading.DispatcherTimer
    $trackTimer.Interval = [TimeSpan]::FromSeconds(1)
    $script:DfTrackPid = $null

    $trackTimer.Add_Tick({
        if (-not $script:DfTrackPid) { return }
        try {
            $conns = Get-NetTCPConnection -OwningProcess $script:DfTrackPid -State Established -ErrorAction SilentlyContinue
            foreach ($c in $conns) {
                $ip = $c.RemoteAddress
                if ($ip -and $ip -notmatch '^(127\.|::1$|169\.254\.|0\.0\.0\.0)') {
                    [void]$collectedIPs.Add($ip)
                }
            }
            $dfStatus.Text = "Отслеживание идёт... уникальных TCP-адресов: $($collectedIPs.Count). Захват трафика тоже идёт в фоне."
        } catch {}
    })

    $btnDfStart.Add_Click({
        if (-not $cmbDfProcess.SelectedItem) {
            $dfStatus.Text = "Сначала выберите процесс из списка."
            return
        }
        $collectedIPs.Clear()
        $lstDfDomains.Items.Clear()
        $script:DfTrackPid = $cmbDfProcess.SelectedItem.Tag
        $dfStatus.Text = "Отслеживание идёт... пользуйтесь приложением, чтобы оно обращалось к серверам."
        $btnDfStart.IsEnabled = $false
        $btnDfUrlGo.IsEnabled = $false
        $btnDfStop.IsEnabled = $true
        $cmbDfProcess.IsEnabled = $false
        Start-DfPktmonCapture
        $trackTimer.Start()
    })

    $btnDfStop.Add_Click({
        $trackTimer.Stop()
        $btnDfStop.IsEnabled = $false
        $dfStatus.Text = "Обрабатываю захваченный трафик..."
        $pktmonDomains = Stop-DfPktmonCapture
        $btnDfStart.IsEnabled = $true
        $btnDfUrlGo.IsEnabled = $true
        $cmbDfProcess.IsEnabled = $true
        Show-DfProcessResults -DnsMap (Get-DfDnsSnapshot) -PktmonDomains $pktmonDomains
    })

    $dfWindow.Add_Closing({
        $trackTimer.Stop()
        $cdpTimer.Stop()
        if ($script:DfCdpJob) { Remove-Job -Job $script:DfCdpJob -Force -ErrorAction SilentlyContinue }
        if ($script:DfPktmonPath) {
            try { & pktmon stop 2>$null | Out-Null } catch {}
            Remove-Item $script:DfPktmonPath -Force -ErrorAction SilentlyContinue
        }
    })
    [void]$dfWindow.ShowDialog()
}

function Show-UpdateDialog {
    param([string]$LocalVersion, [string]$RemoteVersion, [string]$DestPath, [string]$Changelog)

    [xml]$dlgXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Обновление Zapret" Width="460" Height="520" MinHeight="420"
        WindowStartupLocation="CenterOwner" ResizeMode="CanResizeWithGrip"
        Background="#0B0B12" FontFamily="Segoe UI">
    <Grid Margin="24">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <StackPanel Orientation="Horizontal" Grid.Row="0">
            <Border Width="40" Height="40" CornerRadius="20">
                <Border.Background>
                    <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                        <GradientStop Color="#8E44E0" Offset="0"/>
                        <GradientStop Color="#E63950" Offset="1"/>
                    </LinearGradientBrush>
                </Border.Background>
                <TextBlock Text="&#8593;" FontSize="18" FontWeight="Bold" Foreground="White" HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <TextBlock Text="Доступно обновление" Foreground="White" FontSize="17" FontWeight="Bold" VerticalAlignment="Center" Margin="12,0,0,0"/>
        </StackPanel>

        <TextBlock Grid.Row="1" Margin="0,18,0,0" Foreground="#B7B7C2" FontSize="13">
            <Run Text="Установлена версия: "/><Run x:Name="runLocal" FontWeight="Bold" Foreground="White"/>
        </TextBlock>
        <StackPanel Grid.Row="2" Orientation="Horizontal" Margin="0,4,0,0">
            <TextBlock Foreground="#B7B7C2" FontSize="13" Text="Доступна версия: "/>
            <TextBlock x:Name="runRemote" FontWeight="Bold" Foreground="#00E28A" FontSize="13"/>
        </StackPanel>

        <Border Grid.Row="3" Background="#12121B" CornerRadius="8" Margin="0,16,0,0" Padding="12,10">
            <TextBlock x:Name="pathText" Foreground="#8A8A99" FontSize="11.5" TextWrapping="Wrap"/>
        </Border>

        <Border Grid.Row="4" Background="#12121B" CornerRadius="8" Margin="0,14,0,0" Padding="14,12" MinHeight="80">
            <StackPanel>
                <TextBlock Text="Что нового:" Foreground="#8A8A99" FontSize="11.5" FontWeight="SemiBold" Margin="0,0,0,8"/>
                <ScrollViewer VerticalScrollBarVisibility="Auto" MaxHeight="220">
                    <TextBlock x:Name="changelogText" Foreground="#D8D8E0" FontSize="12.5" TextWrapping="Wrap" LineHeight="19"/>
                </ScrollViewer>
            </StackPanel>
        </Border>

        <StackPanel Grid.Row="5" Orientation="Horizontal" Margin="0,20,0,0">
            <Button x:Name="btnUpdateYes" Content="Скачать" Width="160" Height="42" Foreground="White" BorderThickness="0" FontSize="14" Margin="0,0,12,0" Cursor="Hand">
                <Button.Background>
                    <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                        <GradientStop Color="#8E44E0" Offset="0"/>
                        <GradientStop Color="#E63950" Offset="1"/>
                    </LinearGradientBrush>
                </Button.Background>
            </Button>
            <Button x:Name="btnUpdateNo" Content="Отмена" Width="120" Height="42" Background="#1B1B27" Foreground="White" BorderThickness="0" FontSize="14" Cursor="Hand"/>
        </StackPanel>
    </Grid>
</Window>
"@

    $reader3 = New-Object System.Xml.XmlNodeReader $dlgXaml
    $dlgWindow = [Windows.Markup.XamlReader]::Load($reader3)
    try { $dlgWindow.Owner = $window } catch {}

    $runLocal = $dlgWindow.FindName("runLocal")
    $runRemote = $dlgWindow.FindName("runRemote")
    $pathText = $dlgWindow.FindName("pathText")
    $changelogText = $dlgWindow.FindName("changelogText")
    $btnUpdateYes = $dlgWindow.FindName("btnUpdateYes")
    $btnUpdateNo = $dlgWindow.FindName("btnUpdateNo")

    $runLocal.Text = $LocalVersion
    $runRemote.Text = $RemoteVersion
    $pathText.Text = "Файлы стратегий будут обновлены в папке:`n$DestPath"
    if ($Changelog) {
        $changelogText.Text = $Changelog
    } else {
        $changelogText.Text = "Список изменений недоступен (не удалось получить данные с GitHub)."
    }

    $script:UpdateDialogResult = $false
    $btnUpdateYes.Add_Click({ $script:UpdateDialogResult = $true; $dlgWindow.Close() })
    $btnUpdateNo.Add_Click({ $script:UpdateDialogResult = $false; $dlgWindow.Close() })

    [void]$dlgWindow.ShowDialog()
    return $script:UpdateDialogResult
}

function Show-AvatarEditor {
    param([string]$SourcePath)

    [xml]$editorXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Редактор аватара" Width="340" Height="480"
        WindowStartupLocation="CenterOwner" ResizeMode="NoResize"
        Background="#0B0B12" FontFamily="Segoe UI">
    <StackPanel Margin="20">
        <TextBlock Text="Перетащите и увеличьте фото" Foreground="White" FontSize="14" FontWeight="SemiBold" Margin="0,0,0,14" HorizontalAlignment="Center"/>
        <Grid Width="260" Height="260" HorizontalAlignment="Center">
            <Border CornerRadius="130" ClipToBounds="True" Background="#1B1B27">
                <Canvas x:Name="cropCanvas" Width="260" Height="260" ClipToBounds="True">
                    <Image x:Name="cropImage" Stretch="Uniform" RenderTransformOrigin="0.5,0.5" Cursor="SizeAll">
                        <Image.RenderTransform>
                            <ScaleTransform x:Name="cropScale" ScaleX="1" ScaleY="1"/>
                        </Image.RenderTransform>
                    </Image>
                </Canvas>
            </Border>
            <Border CornerRadius="130" BorderBrush="#6B6B78" BorderThickness="1" IsHitTestVisible="False"/>
        </Grid>
        <TextBlock Text="Масштаб" Foreground="#8A8A99" FontSize="11" Margin="0,18,0,4"/>
        <Slider x:Name="zoomSlider" Minimum="1" Maximum="3" Value="1"/>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Center" Margin="0,22,0,0">
            <Button x:Name="btnSaveAvatar" Content="Сохранить" Width="120" Height="36" Foreground="White" BorderThickness="0" Margin="0,0,10,0">
                <Button.Background>
                    <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                        <GradientStop Color="#8E44E0" Offset="0"/>
                        <GradientStop Color="#E63950" Offset="1"/>
                    </LinearGradientBrush>
                </Button.Background>
            </Button>
            <Button x:Name="btnCancelAvatar" Content="Отмена" Width="120" Height="36" Background="#1B1B27" Foreground="White" BorderThickness="0"/>
        </StackPanel>
    </StackPanel>
</Window>
"@

    $reader2 = New-Object System.Xml.XmlNodeReader $editorXaml
    $editorWindow = [Windows.Markup.XamlReader]::Load($reader2)
    $editorWindow.Owner = $window

    $cropCanvas = $editorWindow.FindName("cropCanvas")
    $cropImage = $editorWindow.FindName("cropImage")
    $cropScale = $editorWindow.FindName("cropScale")
    $zoomSlider = $editorWindow.FindName("zoomSlider")
    $btnSaveAvatar = $editorWindow.FindName("btnSaveAvatar")
    $btnCancelAvatar = $editorWindow.FindName("btnCancelAvatar")

    $bitmap = New-Object System.Windows.Media.Imaging.BitmapImage
    $bitmap.BeginInit()
    $bitmap.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
    $bitmap.CreateOptions = [System.Windows.Media.Imaging.BitmapCreateOptions]::IgnoreImageCache
    $bitmap.UriSource = New-Object System.Uri($SourcePath, [System.UriKind]::Absolute)
    $bitmap.EndInit()
    $cropImage.Source = $bitmap
    $cropImage.Width = 260
    $cropImage.Height = 260
    [System.Windows.Controls.Canvas]::SetLeft($cropImage, 0)
    [System.Windows.Controls.Canvas]::SetTop($cropImage, 0)

    $script:AvatarDragging = $false
    $script:AvatarDragStart = New-Object System.Windows.Point(0, 0)
    $script:AvatarImgStart = New-Object System.Windows.Point(0, 0)

    $cropImage.Add_MouseLeftButtonDown({
        param($s, $e)
        $script:AvatarDragging = $true
        $script:AvatarDragStart = $e.GetPosition($cropCanvas)
        $script:AvatarImgStart = New-Object System.Windows.Point(
            [System.Windows.Controls.Canvas]::GetLeft($cropImage),
            [System.Windows.Controls.Canvas]::GetTop($cropImage))
        $cropImage.CaptureMouse()
    })
    $cropImage.Add_MouseMove({
        param($s, $e)
        if ($script:AvatarDragging) {
            $pos = $e.GetPosition($cropCanvas)
            $dx = $pos.X - $script:AvatarDragStart.X
            $dy = $pos.Y - $script:AvatarDragStart.Y
            [System.Windows.Controls.Canvas]::SetLeft($cropImage, $script:AvatarImgStart.X + $dx)
            [System.Windows.Controls.Canvas]::SetTop($cropImage, $script:AvatarImgStart.Y + $dy)
        }
    })
    $cropImage.Add_MouseLeftButtonUp({
        $script:AvatarDragging = $false
        $cropImage.ReleaseMouseCapture()
    })

    $zoomSlider.Add_ValueChanged({
        $cropScale.ScaleX = $zoomSlider.Value
        $cropScale.ScaleY = $zoomSlider.Value
    })

    $btnCancelAvatar.Add_Click({ $editorWindow.Close() })

    $btnSaveAvatar.Add_Click({
        try {
            $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap(260, 260, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
            $cropCanvas.Measure((New-Object System.Windows.Size(260, 260)))
            $cropCanvas.Arrange((New-Object System.Windows.Rect(0, 0, 260, 260)))
            $rtb.Render($cropCanvas)

            $ellipseGeom = New-Object System.Windows.Media.EllipseGeometry((New-Object System.Windows.Rect(0, 0, 260, 260)))
            $visual = New-Object System.Windows.Media.DrawingVisual
            $dc = $visual.RenderOpen()
            $dc.PushClip($ellipseGeom)
            $dc.DrawImage($rtb, (New-Object System.Windows.Rect(0, 0, 260, 260)))
            $dc.Pop()
            $dc.Close()
            $finalBmp = New-Object System.Windows.Media.Imaging.RenderTargetBitmap(260, 260, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
            $finalBmp.Render($visual)

            $destDir = Join-Path $ZapretDir "assets"
            if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
            $destPath = Join-Path $destDir "user_avatar.png"

            $encoder = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
            [void]$encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($finalBmp))
            $stream = [System.IO.File]::Open($destPath, [System.IO.FileMode]::Create)
            $encoder.Save($stream)
            $stream.Close()

            Set-Content -Path $script:AvatarConfigFile -Value $destPath -Force
            Set-AvatarImage -ImagePath $destPath
            $editorWindow.Close()
        } catch {
            [System.Windows.MessageBox]::Show("Не удалось сохранить аватар: $($_.Exception.Message)", "Zapret") | Out-Null
        }
    })

    [void]$editorWindow.ShowDialog()
}

function Start-AvatarPicker {
    try {
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Filter = "Изображения|*.jpg;*.jpeg;*.png;*.bmp;*.gif"
        $dlg.Title = "Выберите фото"
        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            Show-AvatarEditor -SourcePath $dlg.FileName
        }
    } catch {
        Update-Log -Clear -Lines @("Ошибка выбора файла: $($_.Exception.Message)")
    }
}

function Show-AvatarMenu {
    $menu = New-Object System.Windows.Controls.ContextMenu
    try { $menu.Style = $window.FindResource("AnimatedContextMenuStyle") } catch {}

    $itemChange = New-Object System.Windows.Controls.MenuItem
    $itemChange.Header = "Изменить фото"
    try { $itemChange.Style = $window.FindResource("AnimatedMenuItemStyle") } catch {}

    $itemDelete = New-Object System.Windows.Controls.MenuItem
    $itemDelete.Header = "Удалить аватар"
    $itemDelete.IsEnabled = $script:HasAvatar
    try { $itemDelete.Style = $window.FindResource("AnimatedMenuItemStyle") } catch {}

    [void]$menu.Items.Add($itemChange)
    [void]$menu.Items.Add($itemDelete)

    $itemChange.Add_Click({ Start-AvatarPicker })
    $itemDelete.Add_Click({ Remove-Avatar })

    $avatarBorder.ContextMenu = $menu
    $menu.PlacementTarget = $avatarBorder
    $menu.IsOpen = $true
}

if ($avatarBorder) {
    $avatarBorder.Add_MouseLeftButtonUp({
        try { Show-AvatarMenu } catch { Update-Log -Clear -Lines @("Ошибка меню аватара: $($_.Exception.Message)") }
    })
    Import-SavedAvatar
}

Import-ActiveStrategy
Refresh-StatusUI

# ---------------------------------------------------------------
# Иконка в системном трее
# ---------------------------------------------------------------
$notifyIcon = New-Object System.Windows.Forms.NotifyIcon
$script:AppIcoFile = Join-Path $ZapretDir "assets\zapret.ico"
$trayIcon = $null
if (Test-Path -LiteralPath $script:AppIcoFile) { try { $trayIcon = New-Object System.Drawing.Icon($script:AppIcoFile) } catch {} }
if (-not $trayIcon -and $SelfPath -like "*.exe") { try { $trayIcon = [System.Drawing.Icon]::ExtractAssociatedIcon($SelfPath) } catch {} }
if (-not $trayIcon) { $trayIcon = [System.Drawing.SystemIcons]::Shield }
$notifyIcon.Icon = $trayIcon
# значок окна (заголовок и панель задач) — берём самый крупный кадр из .ico
if (Test-Path -LiteralPath $script:AppIcoFile) {
    try {
        $icoDecoder = [System.Windows.Media.Imaging.BitmapDecoder]::Create([Uri]$script:AppIcoFile, [System.Windows.Media.Imaging.BitmapCreateOptions]::None, [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
        $window.Icon = ($icoDecoder.Frames | Sort-Object PixelWidth -Descending | Select-Object -First 1)
    } catch {}
}
$notifyIcon.Visible = $true
$notifyIcon.Text = "Zapret BETA"

$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
$itemShow = New-Object System.Windows.Forms.ToolStripMenuItem "Открыть окно"
$itemToggle = New-Object System.Windows.Forms.ToolStripMenuItem "Включить"
$itemExit = New-Object System.Windows.Forms.ToolStripMenuItem "Выход"
[void]$trayMenu.Items.Add($itemShow)
[void]$trayMenu.Items.Add($itemToggle)
[void]$trayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
[void]$trayMenu.Items.Add($itemExit)
$notifyIcon.ContextMenuStrip = $trayMenu

function Update-TrayMenu {
    $s = Get-ZapretStatus
    $itemToggle.Text = if ($s.On) { "Выключить zapret" } else { "Включить zapret" }
    $notifyIcon.Text = "Zapret — $($s.Text)"
}
$script:UpdateTray = { Update-TrayMenu }
Update-TrayMenu

$itemShow.Add_Click({
    $window.ShowInTaskbar = $true
    $window.Show()
    $window.WindowState = "Normal"
    $window.Activate()
})
$notifyIcon.Add_DoubleClick({
    $window.ShowInTaskbar = $true
    $window.Show()
    $window.WindowState = "Normal"
    $window.Activate()
})
$itemToggle.Add_Click({ Start-ToggleZapret })

$script:AllowClose = $false
$itemExit.Add_Click({
    $script:AllowClose = $true
    $notifyIcon.Visible = $false
    $notifyIcon.Dispose()
    $window.Close()
})

$window.Add_Closing({
    param($s, $e)
    if ($script:AllowClose) {
        $notifyIcon.Visible = $false
        $notifyIcon.Dispose()
        return
    }

    $e.Cancel = $true
    $choice = [System.Windows.MessageBox]::Show(
        "Свернуть Zapret в трей (программа продолжит работать в фоне)?`n`nДа — свернуть в трей`nНет — закрыть программу полностью",
        "Zapret",
        [System.Windows.MessageBoxButton]::YesNoCancel,
        [System.Windows.MessageBoxImage]::Question
    )

    if ($choice -eq [System.Windows.MessageBoxResult]::Yes) {
        $window.Hide()
        $window.ShowInTaskbar = $false
        $notifyIcon.BalloonTipTitle = "Zapret"
        $notifyIcon.BalloonTipText = "Программа свёрнута в трей. Zapret продолжает работать в фоне."
        $notifyIcon.ShowBalloonTip(1500)
    } elseif ($choice -eq [System.Windows.MessageBoxResult]::No) {
        $script:AllowClose = $true
        $window.Dispatcher.BeginInvoke([Action]{ $window.Close() }, [System.Windows.Threading.DispatcherPriority]::Background) | Out-Null
    }
    # Cancel — ничего не делаем, окно остаётся открытым
})

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(5)
$timer.Add_Tick({
    try { Refresh-StatusUI; Update-TrayMenu } catch {}
})
$timer.Start()

$uptimeTimer = New-Object System.Windows.Threading.DispatcherTimer
$uptimeTimer.Interval = [TimeSpan]::FromSeconds(1)
$uptimeTimer.Add_Tick({
    try { Update-Uptime } catch {}
})
$uptimeTimer.Start()

function Play-IntroEffect {
    try {
        # Начальная белая вспышка (как удар молнии)
        $flashAnim = New-Object System.Windows.Media.Animation.DoubleAnimationUsingKeyFrames
        foreach ($p in @(@(0,0), @(30,0.85), @(90,0.1), @(140,0.6), @(220,0))) {
            $kf = New-Object System.Windows.Media.Animation.DiscreteDoubleKeyFrame
            $kf.KeyTime = [TimeSpan]::FromMilliseconds($p[0]); $kf.Value = $p[1]
            [void]$flashAnim.KeyFrames.Add($kf)
        }
        $introFlash.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $flashAnim)

        # Мигание неоновой рамки по краям окна (глитч-вспышки), растянуто дольше
        $borderAnim = New-Object System.Windows.Media.Animation.DoubleAnimationUsingKeyFrames
        $bTimes = @(0, 60, 130, 190, 260, 340, 430, 520, 620, 730, 850, 980, 1120, 1260, 1450)
        $bVals  = @(0, 1, 0.15, 1, 0, 0.9, 0.1, 1, 0.35, 0.8, 0.15, 0.9, 0.3, 0.6, 0)
        for ($i = 0; $i -lt $bTimes.Count; $i++) {
            $kf = New-Object System.Windows.Media.Animation.DiscreteDoubleKeyFrame
            $kf.KeyTime = [TimeSpan]::FromMilliseconds($bTimes[$i])
            $kf.Value = $bVals[$i]
            [void]$borderAnim.KeyFrames.Add($kf)
        }
        $introBorder.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $borderAnim)

        # Дрожание (VHS-тряска) всего окна — дольше и заметнее
        $shakeAnim = New-Object System.Windows.Media.Animation.DoubleAnimationUsingKeyFrames
        $sTimes = @(0, 40, 80, 120, 160, 210, 260, 320, 390, 470, 560, 660, 780)
        $sVals  = @(0, -9, 8, -7, 6, -5, 6, -4, 3, -2, 2, -1, 0)
        for ($i = 0; $i -lt $sTimes.Count; $i++) {
            $kf = New-Object System.Windows.Media.Animation.LinearDoubleKeyFrame
            $kf.KeyTime = [TimeSpan]::FromMilliseconds($sTimes[$i])
            $kf.Value = $sVals[$i]
            [void]$shakeAnim.KeyFrames.Add($kf)
        }
        $rootShakeTransform.BeginAnimation([System.Windows.Media.TranslateTransform]::XProperty, $shakeAnim)

        # Лёгкий пульс масштаба в такт тряске
        $scaleAnim = New-Object System.Windows.Media.Animation.DoubleAnimationUsingKeyFrames
        foreach ($p in @(@(0,1), @(80,1.015), @(180,0.995), @(320,1.008), @(500,1), @(780,1))) {
            $kf = New-Object System.Windows.Media.Animation.LinearDoubleKeyFrame
            $kf.KeyTime = [TimeSpan]::FromMilliseconds($p[0]); $kf.Value = $p[1]
            [void]$scaleAnim.KeyFrames.Add($kf)
        }
        $rootScaleTransform.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty, $scaleAnim)
        $rootScaleTransform.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, $scaleAnim)

        # Молнии-стрики по диагоналям — каждая вспыхивает в свой момент
        $streak1Anim = New-Object System.Windows.Media.Animation.DoubleAnimationUsingKeyFrames
        foreach ($p in @(@(0,0), @(80,1), @(160,0), @(200,0.8), @(260,0))) {
            $kf = New-Object System.Windows.Media.Animation.DiscreteDoubleKeyFrame
            $kf.KeyTime = [TimeSpan]::FromMilliseconds($p[0]); $kf.Value = $p[1]
            [void]$streak1Anim.KeyFrames.Add($kf)
        }
        $introStreak1.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $streak1Anim)

        $streak2Anim = New-Object System.Windows.Media.Animation.DoubleAnimationUsingKeyFrames
        foreach ($p in @(@(0,0), @(0,0), @(340,0), @(420,1), @(470,0.1), @(540,0.9), @(620,0))) {
            $kf = New-Object System.Windows.Media.Animation.DiscreteDoubleKeyFrame
            $kf.KeyTime = [TimeSpan]::FromMilliseconds($p[0]); $kf.Value = $p[1]
            [void]$streak2Anim.KeyFrames.Add($kf)
        }
        $introStreak2.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $streak2Anim)

        $streak3Anim = New-Object System.Windows.Media.Animation.DoubleAnimationUsingKeyFrames
        foreach ($p in @(@(0,0), @(700,0), @(760,1), @(820,0), @(880,0.7), @(950,0))) {
            $kf = New-Object System.Windows.Media.Animation.DiscreteDoubleKeyFrame
            $kf.KeyTime = [TimeSpan]::FromMilliseconds($p[0]); $kf.Value = $p[1]
            [void]$streak3Anim.KeyFrames.Add($kf)
        }
        $introStreak3.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $streak3Anim)

        # Бегущая неоновая линия скана — два прохода сверху вниз
        $introScanLine.Opacity = 1
        $scanAnim = New-Object System.Windows.Media.Animation.DoubleAnimationUsingKeyFrames
        $scanKeys = @(
            @(0, 0), @(500, 740), @(560, 0), @(1100, 740)
        )
        foreach ($p in $scanKeys) {
            $kf = New-Object System.Windows.Media.Animation.LinearDoubleKeyFrame
            $kf.KeyTime = [TimeSpan]::FromMilliseconds($p[0]); $kf.Value = $p[1]
            [void]$scanAnim.KeyFrames.Add($kf)
        }
        $scanAnim.add_Completed({ $introScanLine.Opacity = 0 })
        $introScanTransform.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, $scanAnim)
    } catch {}
}

$script:FirstRunFlag = Join-Path $UtilsDir "gui_first_run.done"
$window.Add_Loaded({
    try {
        if (-not (Test-Path $script:FirstRunFlag)) {
            New-Item -ItemType File -Path $script:FirstRunFlag -Force | Out-Null
            Play-IntroEffect
            $script:IntroTimer = New-Object System.Windows.Threading.DispatcherTimer
            $script:IntroTimer.Interval = [TimeSpan]::FromMilliseconds(1650)
            $script:IntroTimer.add_Tick({
                $script:IntroTimer.Stop()
                $choice = [System.Windows.MessageBox]::Show(
                    "Не хотите проверить все стратегии на работоспособность?`n`nЭто займёт какое-то время (тест каждой — около минуты), но после этого сразу будет видно, какие стратегии рабочие — по цветным точкам в списке слева.",
                    "Zapret — первый запуск",
                    [System.Windows.MessageBoxButton]::YesNo,
                    [System.Windows.MessageBoxImage]::Question
                )
                if ($choice -eq [System.Windows.MessageBoxResult]::Yes) {
                    Start-BatchTest
                }
            })
            $script:IntroTimer.Start()
        }
    } catch {}
})

# ---------------------------------------------------------------
# Обои приложения
# ---------------------------------------------------------------
$script:WallpaperConfigFile = Join-Path $UtilsDir "gui_wallpaper.txt"
$script:WallpaperOpen = $false
$script:HasWallpaper = $false

$LEFT_SLIDE = -444
$RIGHT_SLIDE = 900

function Start-NeonGlow {
    try {
        $anim1 = New-Object System.Windows.Media.Animation.ColorAnimation
        $anim1.From = [System.Windows.Media.ColorConverter]::ConvertFromString("#E63950")
        $anim1.To = [System.Windows.Media.ColorConverter]::ConvertFromString("#8E44E0")
        $anim1.Duration = [TimeSpan]::FromSeconds(1.4)
        $anim1.AutoReverse = $true
        $anim1.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
        $wallpaperTabStop1.BeginAnimation([System.Windows.Media.GradientStop]::ColorProperty, $anim1)

        $anim2 = New-Object System.Windows.Media.Animation.ColorAnimation
        $anim2.From = [System.Windows.Media.ColorConverter]::ConvertFromString("#8E44E0")
        $anim2.To = [System.Windows.Media.ColorConverter]::ConvertFromString("#E63950")
        $anim2.Duration = [TimeSpan]::FromSeconds(1.4)
        $anim2.AutoReverse = $true
        $anim2.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
        $wallpaperTabStop2.BeginAnimation([System.Windows.Media.GradientStop]::ColorProperty, $anim2)
    } catch {}
}

function Stop-NeonGlow {
    try {
        $wallpaperTabStop1.BeginAnimation([System.Windows.Media.GradientStop]::ColorProperty, $null)
        $wallpaperTabStop2.BeginAnimation([System.Windows.Media.GradientStop]::ColorProperty, $null)
        $wallpaperTabStop1.Color = [System.Windows.Media.ColorConverter]::ConvertFromString("#2A2A38")
        $wallpaperTabStop2.Color = [System.Windows.Media.ColorConverter]::ConvertFromString("#2A2A38")
    } catch {}
}

function Set-PanelsTranslucent {
    param([bool]$Translucent)
    try {
        $sidebarColor = if ($Translucent) { "#CC0F0F17" } else { "#FF0F0F17" }
        $listColor = if ($Translucent) { "#CC12121B" } else { "#FF12121B" }
        $mainColor = if ($Translucent) { "#B30B0B12" } else { "#FF0B0B12" }
        $sidebarPanel.Background = [System.Windows.Media.BrushConverter]::new().ConvertFrom($sidebarColor)
        $leftListPanel.Background = [System.Windows.Media.BrushConverter]::new().ConvertFrom($listColor)
        $mainContentPanel.Background = [System.Windows.Media.BrushConverter]::new().ConvertFrom($mainColor)
    } catch {}
}

function Move-Panels {
    param([bool]$Open)
    try {
        $targetLeft = if ($Open) { $LEFT_SLIDE } else { 0 }
        $targetRight = if ($Open) { $RIGHT_SLIDE } else { 0 }
        $ease = New-Object System.Windows.Media.Animation.QuadraticEase
        $ease.EasingMode = "EaseInOut"

        $a1 = New-Object System.Windows.Media.Animation.DoubleAnimation
        $a1.To = $targetLeft; $a1.Duration = [TimeSpan]::FromMilliseconds(380); $a1.EasingFunction = $ease
        $sidebarPanel.RenderTransform.BeginAnimation([System.Windows.Media.TranslateTransform]::XProperty, $a1)

        $a2 = New-Object System.Windows.Media.Animation.DoubleAnimation
        $a2.To = $targetLeft; $a2.Duration = [TimeSpan]::FromMilliseconds(380); $a2.EasingFunction = $ease
        $leftListPanel.RenderTransform.BeginAnimation([System.Windows.Media.TranslateTransform]::XProperty, $a2)

        $a3 = New-Object System.Windows.Media.Animation.DoubleAnimation
        $a3.To = $targetRight; $a3.Duration = [TimeSpan]::FromMilliseconds(380); $a3.EasingFunction = $ease
        if ($Open) {
            $script:PendingShowOverlay = $wallpaperOverlay
            $a3.add_Completed({
                try {
                    $script:PendingShowOverlay.Visibility = "Visible"
                    $fade = New-Object System.Windows.Media.Animation.DoubleAnimation
                    $fade.From = 0; $fade.To = 1; $fade.Duration = [TimeSpan]::FromMilliseconds(220)
                    $script:PendingShowOverlay.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $fade)
                } catch {
                    Update-Log -Clear -Lines @(
                        "Ошибка появления панели обоев: $($_.Exception.Message)",
                        "Строка $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())"
                    )
                }
            })
        }
        $mainContentPanel.RenderTransform.BeginAnimation([System.Windows.Media.TranslateTransform]::XProperty, $a3)
    } catch {
        Update-Log -Clear -Lines @(
            "Ошибка анимации панелей: $($_.Exception.Message)",
            "Строка $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())"
        )
    }
}

function Open-WallpaperEditor {
    $script:WallpaperOpen = $true
    Stop-NeonGlow
    $btnRemoveWallpaper.Visibility = if ($script:HasWallpaper) { "Visible" } else { "Collapsed" }
    $btnSetWallpaper.Content = if ($script:HasWallpaper) { "Изменить обои" } else { "Установить обои" }
    Move-Panels -Open $true
}

function Close-WallpaperEditor {
    $script:WallpaperOpen = $false
    $wallpaperOverlay.Visibility = "Collapsed"
    Move-Panels -Open $false
    Start-NeonGlow
}
$btnWallpaperBack.Add_Click({ Close-WallpaperEditor })

function Set-WallpaperImage {
    param([string]$ImagePath)
    try {
        $bitmap = New-Object System.Windows.Media.Imaging.BitmapImage
        $bitmap.BeginInit()
        $bitmap.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $bitmap.CreateOptions = [System.Windows.Media.Imaging.BitmapCreateOptions]::IgnoreImageCache
        $bitmap.UriSource = New-Object System.Uri($ImagePath, [System.UriKind]::Absolute)
        $bitmap.EndInit()
        $bitmap.Freeze()
        $wallpaperImage.Source = $bitmap
        $blur = New-Object System.Windows.Media.Effects.BlurEffect
        $blur.Radius = 18
        $wallpaperImage.Effect = $blur
        $wallpaperImage.Visibility = "Visible"
        Set-PanelsTranslucent -Translucent $true
        $script:HasWallpaper = $true
    } catch {
        [System.Windows.MessageBox]::Show("Не удалось загрузить изображение: $($_.Exception.Message)", "Zapret") | Out-Null
    }
}

function Import-SavedWallpaper {
    if (Test-Path $script:WallpaperConfigFile) {
        $p = (Get-Content $script:WallpaperConfigFile -Raw -ErrorAction SilentlyContinue)
        if ($p) { $p = $p.Trim() }
        if ($p -and (Test-Path $p)) { Set-WallpaperImage -ImagePath $p }
    }
}

function Remove-Wallpaper {
    try {
        if (Test-Path $script:WallpaperConfigFile) {
            $p = (Get-Content $script:WallpaperConfigFile -Raw -ErrorAction SilentlyContinue)
            if ($p) { $p = $p.Trim() }
            if ($p -and (Test-Path $p)) { Remove-Item $p -Force -ErrorAction SilentlyContinue }
            Remove-Item $script:WallpaperConfigFile -Force -ErrorAction SilentlyContinue
        }
    } catch {}
    $wallpaperImage.Visibility = "Collapsed"
    $wallpaperImage.Source = $null
    Set-PanelsTranslucent -Translucent $false
    $script:HasWallpaper = $false
}

$wallpaperTab.Add_MouseLeftButtonUp({
    try {
        if ($script:WallpaperOpen) { Close-WallpaperEditor } else { Open-WallpaperEditor }
    } catch {
        Update-Log -Clear -Lines @("Ошибка панели обоев: $($_.Exception.Message)")
    }
})

$btnSetWallpaper.Add_Click({
    try {
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Filter = "Изображения|*.jpg;*.jpeg;*.png;*.bmp"
        $dlg.Title = "Выберите фон"
        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $destDir = Join-Path $ZapretDir "assets"
            if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
            $ext = [System.IO.Path]::GetExtension($dlg.FileName)
            $destPath = Join-Path $destDir "user_wallpaper$ext"
            Copy-Item -Path $dlg.FileName -Destination $destPath -Force
            Set-Content -Path $script:WallpaperConfigFile -Value $destPath -Force
            Set-WallpaperImage -ImagePath $destPath
            Close-WallpaperEditor
        }
    } catch {
        [System.Windows.MessageBox]::Show("Ошибка выбора файла: $($_.Exception.Message)", "Zapret") | Out-Null
    }
})

$btnRemoveWallpaper.Add_Click({
    Remove-Wallpaper
    Close-WallpaperEditor
})

try { Import-SavedWallpaper } catch {}
try { Start-NeonGlow } catch {}

# ---------------------------------------------------------------
# Плеер (кнопка с нотой)
# ---------------------------------------------------------------
$script:PlaylistDir = Join-Path $ZapretDir "assets\playlist"
$script:Playlist = @()
$script:TrackIndex = -1
$script:PlayerPlaying = $false
$script:AudioReactionActive = $false
$script:AudioStartedAt = 0
$script:GlowCurrent = 0.0
$script:GlowDriverTimer = $null
$script:GlowModeLogged = ""
$script:BassMeterInstance = $null

# Запасной узор на случай, если реальный захват звука недоступен: @(время мс, уровень)
$script:SimPattern = @(
    @(0, 0.15), @(220, 0.9), @(340, 0.25), @(500, 0.95), @(620, 0.2),
    @(900, 0.85), @(1000, 0.15), @(1150, 0.6), @(1400, 0.1),
    @(1900, 0.9), @(2050, 0.2), @(2300, 0.75), @(2600, 0.15)
)

function Get-SimulatedBassLevel {
    $period = 2600
    $t = ([Environment]::TickCount -band 0x7FFFFFFF) % $period
    $pat = $script:SimPattern
    for ($i = 0; $i -lt ($pat.Count - 1); $i++) {
        $t0 = $pat[$i][0]
        $t1 = $pat[$i + 1][0]
        if ($t -ge $t0 -and $t -le $t1) {
            $span = $t1 - $t0
            if ($span -le 0) { return [double]$pat[$i][1] }
            $k = ($t - $t0) / $span
            return [double]($pat[$i][1] + ($pat[$i + 1][1] - $pat[$i][1]) * $k)
        }
    }
    return 0.15
}

# Один кадр свечения (вызывается таймером ~30 раз в секунду).
# Прозрачность рамки выставляется напрямую, без WPF-анимаций: анимация с HoldEnd
# "перекрывает" значения, заданные из кода, и после первой паузы эффект переставал работать.
function Update-GlowFrame {
    $target = 0.0
    $mode = ""
    if ($script:AudioReactionActive) {
        $meter = $script:BassMeterInstance
        if ($meter -and $meter.IsCapturing) {
            $target = [double]$meter.BassLevel
            $mode = "real"
        } elseif ($meter -and (-not $meter.LastError) -and (([Environment]::TickCount - $script:AudioStartedAt) -lt 2500)) {
            # захват ещё запускается — подождём, ничего не рисуем
            $mode = ""
        } else {
            $target = Get-SimulatedBassLevel
            $mode = "sim"
        }
    }

    # В лог пишем только при смене режима, а не на каждый кадр/трек
    if ($mode -ne "" -and $mode -ne $script:GlowModeLogged) {
        $script:GlowModeLogged = $mode
        try {
            if ($mode -eq "real") {
                Update-Log -Lines @("Аудио: реальный анализ баса активен ($($script:BassMeterInstance.Info)).")
            } else {
                $why = "захват звука не запустился"
                if (-not $script:BassMeterAvailable) {
                    $why = "модуль захвата звука не скомпилировался: $($script:BassMeterCompileError)"
                } elseif ($script:BassMeterInstance -and $script:BassMeterInstance.LastError) {
                    $why = [string]$script:BassMeterInstance.LastError
                }
                Update-Log -Lines @("Аудио: реальный захват недоступен ($why). Показывается имитация.")
            }
        } catch {}
    }

    # Быстро вверх, плавно вниз
    $cur = $script:GlowCurrent
    if ($target -gt $cur) { $cur += ($target - $cur) * 0.8 } else { $cur += ($target - $cur) * 0.25 }
    if ($cur -lt 0.004) { $cur = 0.0 }
    $script:GlowCurrent = $cur

    try {
        if ($cur -le 0.0) {
            $musicGlowBorder.Opacity = 0.0
        } else {
            $musicGlowBorder.Opacity = [Math]::Min(1.0, 0.10 + 0.90 * $cur)
            if ($musicGlowBorder.Effect) { $musicGlowBorder.Effect.BlurRadius = 14 + 46 * $cur }
        }
    } catch {}

    # Реакция выключена и свечение погасло — таймер больше не нужен
    if ((-not $script:AudioReactionActive) -and $cur -le 0.0) {
        try { $script:GlowDriverTimer.Stop() } catch {}
    }
}

function Start-GlowDriver {
    try {
        # Снимаем возможную остаточную анимацию прозрачности, чтобы она не перекрывала наши значения
        $musicGlowBorder.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)
    } catch {}
    if (-not $script:GlowDriverTimer) {
        $script:GlowDriverTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:GlowDriverTimer.Interval = [TimeSpan]::FromMilliseconds(33)
        $script:GlowDriverTimer.add_Tick({ try { Update-GlowFrame } catch {} })
    }
    if (-not $script:GlowDriverTimer.IsEnabled) { $script:GlowDriverTimer.Start() }
}

function Start-AudioReaction {
    $script:AudioReactionActive = $true
    $script:AudioStartedAt = [Environment]::TickCount
    if ($script:BassMeterAvailable) {
        try {
            if (-not $script:BassMeterInstance) { $script:BassMeterInstance = New-Object ZapretAudio.BassMeter }
            # Start() можно вызывать повторно (смена трека, пауза/продолжить) — второй поток не создаётся
            [void]$script:BassMeterInstance.Start()
        } catch {
            $script:BassMeterInstance = $null
            try { Update-Log -Lines @("Аудио: не удалось запустить захват звука: $($_.Exception.Message)") } catch {}
        }
    }
    Start-GlowDriver
}

function Stop-AudioReaction {
    $script:AudioReactionActive = $false
    try { if ($script:BassMeterInstance) { $script:BassMeterInstance.Stop() } } catch {}
    # Таймер сам плавно погасит свечение и остановится
}

# Значок на кнопке плеера: переключаем два нарисованных символа (без шрифтовых глифов ▶ ⏸)
function Set-PlayerPlayingIcon {
    param([bool]$Playing)
    try {
        if ($Playing) { $playerPlayIcon.Visibility = "Collapsed"; $playerPauseIcon.Visibility = "Visible" }
        else { $playerPlayIcon.Visibility = "Visible"; $playerPauseIcon.Visibility = "Collapsed" }
    } catch {}
}

function Update-TrackLabel {
    if ($script:TrackIndex -ge 0 -and $script:TrackIndex -lt $script:Playlist.Count) {
        $playerTrackName.Text = [System.IO.Path]::GetFileNameWithoutExtension($script:Playlist[$script:TrackIndex])
    } elseif ($script:Playlist.Count -gt 0) {
        $playerTrackName.Text = "Выберите трек"
    } else {
        $playerTrackName.Text = "Плейлист пуст"
    }
}

# Перерисовывает список треков в панели плеера: играющий трек помечен ▶ и выделен
function Update-PlayerListUI {
    $lstPlayerTracks.Items.Clear()
    $playIcon = [string][char]0x25B6
    $noteIcon = [string][char]0x266A
    for ($i = 0; $i -lt $script:Playlist.Count; $i++) {
        $name = [System.IO.Path]::GetFileNameWithoutExtension($script:Playlist[$i])
        $prefix = if ($i -eq $script:TrackIndex) { $playIcon } else { $noteIcon }
        [void]$lstPlayerTracks.Items.Add("$prefix  $name")
    }
    if ($script:TrackIndex -ge 0 -and $script:TrackIndex -lt $script:Playlist.Count) {
        $lstPlayerTracks.SelectedIndex = $script:TrackIndex
        try { $lstPlayerTracks.ScrollIntoView($lstPlayerTracks.SelectedItem) } catch {}
    }
    $playerTracksHeader.Text = "ТРЕКИ ($($script:Playlist.Count))"
    if ($script:Playlist.Count -eq 0) {
        $playerEmptyHint.Visibility = "Visible"
        $lstPlayerTracks.Visibility = "Collapsed"
    } else {
        $playerEmptyHint.Visibility = "Collapsed"
        $lstPlayerTracks.Visibility = "Visible"
    }
}

# Заново читает папку assets\playlist. Если играющий трек остался в папке — продолжает его,
# если файл удалили — останавливает воспроизведение.
function Update-PlaylistFromDisk {
    $currentPath = $null
    if ($script:TrackIndex -ge 0 -and $script:TrackIndex -lt $script:Playlist.Count) {
        $currentPath = $script:Playlist[$script:TrackIndex]
    }
    $newList = @()
    try {
        if (-not (Test-Path $script:PlaylistDir)) { New-Item -ItemType Directory -Path $script:PlaylistDir -Force | Out-Null }
        $newList = @(Get-ChildItem -LiteralPath $script:PlaylistDir -Filter "*.mp3" -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -ExpandProperty FullName)
    } catch {}
    $script:Playlist = $newList

    if ($currentPath) {
        $idx = [array]::IndexOf($script:Playlist, $currentPath)
        if ($idx -ge 0) {
            $script:TrackIndex = $idx
        } else {
            try { $mediaPlayer.Stop() } catch {}
            $script:PlayerPlaying = $false
            $script:TrackIndex = -1
            Set-PlayerPlayingIcon -Playing $false
            Stop-AudioReaction
        }
    } else {
        $script:TrackIndex = -1
    }
    Update-TrackLabel
    Update-PlayerListUI
}

function Start-Track {
    param([int]$Index)
    if ($script:Playlist.Count -eq 0) { return }
    $Index = (($Index % $script:Playlist.Count) + $script:Playlist.Count) % $script:Playlist.Count
    $script:TrackIndex = $Index
    try {
        $mediaPlayer.Stop()
        $mediaPlayer.Source = New-Object System.Uri($script:Playlist[$Index], [System.UriKind]::Absolute)
        $mediaPlayer.Volume = $volumeSlider.Value
        $mediaPlayer.Play()
        $script:PlayerPlaying = $true
        Set-PlayerPlayingIcon -Playing $true
        Update-TrackLabel
        Update-PlayerListUI
        Start-AudioReaction
    } catch {}
}

$mediaPlayer.Add_MediaEnded({
    if ($script:Playlist.Count -gt 0) { Start-Track -Index ($script:TrackIndex + 1) }
})

$btnPlayer.Add_Click({
    try {
        if ($playerPanel.Visibility -eq "Visible") {
            $playerPanel.Visibility = "Collapsed"
            return
        }
        # Подхватываем новые/удалённые файлы при каждом открытии панели
        Update-PlaylistFromDisk
        $playerPanel.Visibility = "Visible"
    } catch {}
})

$btnPlayerRefresh.Add_Click({
    try { Update-PlaylistFromDisk } catch {}
})

$btnPlayerOpenFolder.Add_Click({
    try {
        if (-not (Test-Path $script:PlaylistDir)) { New-Item -ItemType Directory -Path $script:PlaylistDir -Force | Out-Null }
        Start-Process explorer.exe -ArgumentList "`"$($script:PlaylistDir)`""
    } catch {}
})

$lstPlayerTracks.Add_MouseDoubleClick({
    try {
        $i = $lstPlayerTracks.SelectedIndex
        if ($i -ge 0) { Start-Track -Index $i }
    } catch {}
})

$btnPlayerToggle.Add_Click({
    try {
        if ($script:Playlist.Count -eq 0) { return }
        if ($script:TrackIndex -lt 0) { Start-Track -Index 0; return }
        if ($script:PlayerPlaying) {
            $mediaPlayer.Pause()
            Set-PlayerPlayingIcon -Playing $false
            Stop-AudioReaction
        } else {
            $mediaPlayer.Play()
            Set-PlayerPlayingIcon -Playing $true
            Start-AudioReaction
        }
        $script:PlayerPlaying = -not $script:PlayerPlaying
    } catch {}
})

$btnPlayerPrev.Add_Click({ if ($script:Playlist.Count -gt 0) { Start-Track -Index ($script:TrackIndex - 1) } })
$btnPlayerNext.Add_Click({ if ($script:Playlist.Count -gt 0) { Start-Track -Index ($script:TrackIndex + 1) } })

$btnPlayerClose.Add_MouseLeftButtonUp({
    $playerPanel.Visibility = "Collapsed"
})

$volumeSlider.Add_ValueChanged({
    try { $mediaPlayer.Volume = $volumeSlider.Value } catch {}
})

# ---------------- Автовключение стратегии после обновления ----------------
# Update.ps1 перед остановкой защиты записывает имя включённой стратегии в utils\gui_restore_after_update.txt.
# При первом запуске новой версии программа включает её обратно — теми же шагами, что и кнопка включения.
$script:RestoreMarker = Join-Path $UtilsDir "gui_restore_after_update.txt"

function Restore-StrategyAfterUpdate {
    try {
        if (-not (Test-Path -LiteralPath $script:RestoreMarker)) { return }
        $name = (Get-Content -LiteralPath $script:RestoreMarker -Raw -ErrorAction Stop).Trim()
        Remove-Item -LiteralPath $script:RestoreMarker -Force -ErrorAction SilentlyContinue
        if (-not $name) { return }
        $bat = $name
        if ($bat -notmatch '\.bat$') { $bat += ".bat" }
        $match = $script:Strategies | Where-Object { $_ -eq $bat } | Select-Object -First 1
        if (-not $match) {
            Update-Log -Lines @("После обновления: стратегия «$name» не найдена в новой версии — выберите стратегию вручную.")
            return
        }
        if ((Get-ZapretStatus).On) { return }   # уже включена — ничего не делаем (иначе кнопка переключила бы её в «выкл»)

        # выделяем стратегию в списке так же, как при клике
        foreach ($b in $script:StrategyItems.Values) { $b.Background = [System.Windows.Media.Brushes]::Transparent }
        if ($script:StrategyItems.ContainsKey($match)) {
            $script:StrategyItems[$match].Background = (New-Object System.Windows.Media.BrushConverter).ConvertFromString("#221F35")
        }
        $script:SelectedStrategy = $match
        $lblSelected.Text = ($match -replace '\.bat$', '')

        Update-Log -Lines @("После обновления: включаю стратегию «$($lblSelected.Text)»...")
        Start-ToggleZapret
        if ((Get-ZapretStatus).On) { Update-Log -Lines @("После обновления: защита снова включена.") }
        else { Update-Log -Lines @("После обновления не удалось включить стратегию автоматически — включите её кнопкой.") }
    } catch {
        try { Update-Log -Lines @("После обновления не удалось включить стратегию: $($_.Exception.Message)") } catch {}
    }
}

$restoreTimer = New-Object System.Windows.Threading.DispatcherTimer
$restoreTimer.Interval = [TimeSpan]::FromMilliseconds(1500)
$restoreTimer.Add_Tick({ $restoreTimer.Stop(); Restore-StrategyAfterUpdate })
if (Test-Path -LiteralPath $script:RestoreMarker) { $restoreTimer.Start() }

try { Update-PlaylistFromDisk } catch {}

[void]$window.ShowDialog()
