using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Forms;

namespace EbmFanScan
{
    internal static class Program
    {
        private const string MutexName = "Local\\EBMFanScanLauncher";
        internal const string AppWindowTitle = "Fan Modbus · Cihaz Bulucu";

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern IntPtr FindWindowW(string className, string windowName);

        [DllImport("user32.dll")]
        private static extern bool SetForegroundWindow(IntPtr hWnd);

        [DllImport("user32.dll")]
        private static extern bool ShowWindow(IntPtr hWnd, int command);

        [DllImport("user32.dll")]
        private static extern bool IsIconic(IntPtr hWnd);

        [STAThread]
        private static void Main(string[] args)
        {
            bool createdNew;
            using (var mutex = new Mutex(true, MutexName, out createdNew))
            {
                string installDir = ResolveInstallDir(AppDomain.CurrentDomain.BaseDirectory);

                if (!createdNew)
                {
                    ActivateExisting(installDir);
                    return;
                }

                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);

                try
                {
                    EnsureRuntimeFiles(installDir);
                    bool noBrowser = args.Any(a => string.Equals(a, "--no-browser", StringComparison.OrdinalIgnoreCase));
                    Application.Run(new FanAppContext(installDir, noBrowser));
                }
                catch (Exception ex)
                {
                    MessageBox.Show(
                        "Fan Modbus başlatılamadı.\r\n\r\n" + ex.Message,
                        "Fan Modbus",
                        MessageBoxButtons.OK,
                        MessageBoxIcon.Error);
                }
            }
        }

        private static string ResolveInstallDir(string baseDir)
        {
            string[] required =
            {
                Path.Combine(baseDir, "app", "index.html"),
                Path.Combine(baseDir, "start.ps1")
            };

            bool filesPresent = required.All(File.Exists);
            if (filesPresent && IsWritable(baseDir))
            {
                return baseDir;
            }

            string local = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "EBMFanScan");
            Directory.CreateDirectory(local);
            return local;
        }

        private static bool IsWritable(string dir)
        {
            try
            {
                string probe = Path.Combine(dir, ".write_test_" + Guid.NewGuid().ToString("N"));
                File.WriteAllText(probe, "x");
                File.Delete(probe);
                return true;
            }
            catch
            {
                return false;
            }
        }

        public static string ReadRuntimeUrl(string installDir)
        {
            try
            {
                string file = Path.Combine(installDir, "runtime_url.txt");
                if (!File.Exists(file)) return null;
                string url = File.ReadAllText(file).Trim();
                return url.StartsWith("http", StringComparison.OrdinalIgnoreCase) ? url : null;
            }
            catch
            {
                return null;
            }
        }

        private static void EnsureRuntimeFiles(string installDir)
        {
            string[] required =
            {
                Path.Combine(installDir, "app", "index.html"),
                Path.Combine(installDir, "app", "app.js"),
                Path.Combine(installDir, "app", "style.css"),
                Path.Combine(installDir, "start.ps1")
            };
            if (required.All(File.Exists)) return;

            Assembly assembly = Assembly.GetExecutingAssembly();
            string resource = assembly.GetManifestResourceNames()
                .FirstOrDefault(name => name.EndsWith("payload.zip", StringComparison.OrdinalIgnoreCase));
            if (resource == null)
            {
                throw new Exception(
                    "Gömülü program dosyaları bulunamadı. FanModbus.exe'yi app klasörü ve start.ps1 ile birlikte kullanın.");
            }

            using (Stream stream = assembly.GetManifestResourceStream(resource))
            using (var archive = new ZipArchive(stream, ZipArchiveMode.Read))
            {
                string rootFull = Path.GetFullPath(installDir);
                if (!rootFull.EndsWith(Path.DirectorySeparatorChar.ToString()))
                {
                    rootFull += Path.DirectorySeparatorChar;
                }

                foreach (ZipArchiveEntry entry in archive.Entries)
                {
                    if (string.IsNullOrEmpty(entry.Name)) continue;

                    string relative = entry.FullName.Replace('/', Path.DirectorySeparatorChar);
                    string destination = Path.GetFullPath(Path.Combine(installDir, relative));
                    if (!destination.StartsWith(rootFull, StringComparison.OrdinalIgnoreCase))
                    {
                        throw new Exception("Geçersiz arşiv yolu: " + entry.FullName);
                    }

                    Directory.CreateDirectory(Path.GetDirectoryName(destination));
                    entry.ExtractToFile(destination, true);
                }
            }
        }

        internal static IntPtr FindAppWindow()
        {
            try { return FindWindowW(null, AppWindowTitle); }
            catch { return IntPtr.Zero; }
        }

        private static void ActivateExisting(string installDir)
        {
            IntPtr hwnd = FindAppWindow();
            if (hwnd != IntPtr.Zero)
            {
                if (IsIconic(hwnd)) ShowWindow(hwnd, 9);
                SetForegroundWindow(hwnd);
                return;
            }

            string url = ReadRuntimeUrl(installDir);
            if (string.IsNullOrEmpty(url)) return;
            if (StartAppWindow(url, installDir) == null) OpenUrl(url);
        }

        internal static string FindBrowserPath()
        {
            string programFiles = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
            string programFilesX86 = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86);
            string localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);

            string[] candidates =
            {
                Path.Combine(programFilesX86, @"Microsoft\Edge\Application\msedge.exe"),
                Path.Combine(programFiles, @"Microsoft\Edge\Application\msedge.exe"),
                Path.Combine(localAppData, @"Microsoft\Edge\Application\msedge.exe"),
                Path.Combine(programFiles, @"Google\Chrome\Application\chrome.exe"),
                Path.Combine(programFilesX86, @"Google\Chrome\Application\chrome.exe"),
                Path.Combine(localAppData, @"Google\Chrome\Application\chrome.exe")
            };

            return candidates.FirstOrDefault(File.Exists);
        }

        internal static Process StartAppWindow(string url, string installDir)
        {
            string browser = FindBrowserPath();
            if (browser == null) return null;

            string profile = Path.Combine(installDir, "browser-profile");
            try { Directory.CreateDirectory(profile); }
            catch { return null; }

            // A dedicated profile gives this window its own browser process, so
            // closing the window can be detected and ends the whole program.
            string arguments =
                "--app=" + url +
                " --user-data-dir=\"" + profile + "\"" +
                " --no-first-run --no-default-browser-check --disable-sync" +
                " --disable-background-timer-throttling --disable-renderer-backgrounding" +
                " --disable-backgrounding-occluded-windows --start-maximized";

            var info = new ProcessStartInfo(browser, arguments)
            {
                UseShellExecute = false,
                WorkingDirectory = installDir
            };
            return Process.Start(info);
        }

        internal static void OpenUrl(string url)
        {
            try { Process.Start(url); }
            catch { }
        }

        internal static void KillTree(Process process)
        {
            if (process == null) return;
            try
            {
                if (process.HasExited) return;

                string taskkill = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.System),
                    "taskkill.exe");
                var info = new ProcessStartInfo(taskkill, "/PID " + process.Id + " /T /F")
                {
                    UseShellExecute = false,
                    CreateNoWindow = true
                };

                using (Process killer = Process.Start(info))
                {
                    if (killer != null) killer.WaitForExit(4000);
                }
                process.WaitForExit(4000);
            }
            catch { }
        }
    }

    internal sealed class FanAppContext : ApplicationContext
    {
        private readonly string _installDir;
        private readonly bool _noBrowser;
        private readonly string _runtimeFile;
        private readonly StringBuilder _output = new StringBuilder();

        private System.Windows.Forms.Timer _timer;
        private Process _server;
        private Process _browser;
        private NotifyIcon _tray;
        private DateTime _startedAt;
        private string _url;
        private bool _started;
        private bool _windowSeen;
        private int _windowMissing;

        public FanAppContext(string installDir, bool noBrowser)
        {
            _installDir = installDir;
            _noBrowser = noBrowser;
            _runtimeFile = Path.Combine(installDir, "runtime_url.txt");

            _timer = new System.Windows.Forms.Timer();
            _timer.Interval = 250;
            _timer.Tick += delegate { Poll(); };
            _timer.Start();
        }

        private void Poll()
        {
            if (!_started)
            {
                _started = true;
                StartServer();
                return;
            }

            if (_server == null || _server.HasExited)
            {
                if (_url == null) Fail("Sunucu başlatılamadı.\r\n\r\n" + Tail(900));
                else ExitThread();
                return;
            }

            if (_url == null)
            {
                string url = Program.ReadRuntimeUrl(_installDir);
                if (url == null)
                {
                    if ((DateTime.UtcNow - _startedAt).TotalSeconds > 30)
                    {
                        Fail("Sunucu 30 saniye içinde başlamadı.\r\n\r\n" + Tail(900));
                    }
                    return;
                }

                _url = url;
                if (!_noBrowser) LaunchInterface();
                return;
            }

            if (_browser == null) return;

            if (_browser.HasExited)
            {
                if (_windowSeen) ExitThread();
                else UseDefaultBrowser();
                return;
            }

            IntPtr hwnd = Program.FindAppWindow();
            if (hwnd != IntPtr.Zero)
            {
                _windowSeen = true;
                _windowMissing = 0;
                return;
            }

            if (_windowSeen)
            {
                _windowMissing++;
                if (_windowMissing >= 10) ExitThread();
            }
        }

        private void StartServer()
        {
            try
            {
                if (File.Exists(_runtimeFile)) File.Delete(_runtimeFile);
            }
            catch { }

            string script = Path.Combine(_installDir, "start.ps1");
            if (!File.Exists(script))
            {
                Fail("start.ps1 bulunamadı: " + _installDir);
                return;
            }

            var info = new ProcessStartInfo();
            info.FileName = "powershell.exe";
            info.Arguments = "-NoProfile -ExecutionPolicy Bypass -File \"" + script + "\" -NoBrowser";
            info.WorkingDirectory = _installDir;
            info.UseShellExecute = false;
            info.CreateNoWindow = true;
            info.RedirectStandardOutput = true;
            info.RedirectStandardError = true;

            _server = new Process();
            _server.StartInfo = info;
            _server.OutputDataReceived += delegate(object sender, DataReceivedEventArgs ev)
            {
                if (ev.Data != null) AppendOutput(ev.Data);
            };
            _server.ErrorDataReceived += delegate(object sender, DataReceivedEventArgs ev)
            {
                if (ev.Data != null) AppendOutput(ev.Data);
            };

            try
            {
                _server.Start();
                _server.BeginOutputReadLine();
                _server.BeginErrorReadLine();
            }
            catch (Exception ex)
            {
                Fail("Sunucu başlatılamadı: " + ex.Message);
                return;
            }

            _startedAt = DateTime.UtcNow;
        }

        private void LaunchInterface()
        {
            try { _browser = Program.StartAppWindow(_url, _installDir); }
            catch { _browser = null; }
            if (_browser == null) UseDefaultBrowser();
        }

        private void UseDefaultBrowser()
        {
            _browser = null;
            Program.OpenUrl(_url);
            ShowTray();
        }

        private void ShowTray()
        {
            if (_tray != null) return;

            var menu = new ContextMenuStrip();
            menu.Items.Add("Arayüzü Aç", null, delegate { Program.OpenUrl(_url); });
            menu.Items.Add("Klasörü Aç", null, delegate
            {
                try { Process.Start("explorer.exe", "\"" + _installDir + "\""); }
                catch { }
            });
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add("Kapat", null, delegate { ExitThread(); });

            _tray = new NotifyIcon();
            _tray.Icon = SystemIcons.Application;
            _tray.Text = "Fan Modbus";
            _tray.ContextMenuStrip = menu;
            _tray.Visible = true;
        }

        private void Fail(string message)
        {
            MessageBox.Show(message, "Fan Modbus", MessageBoxButtons.OK, MessageBoxIcon.Error);
            ExitThread();
        }

        private void AppendOutput(string line)
        {
            lock (_output)
            {
                _output.AppendLine(line);
                if (_output.Length > 8000)
                {
                    _output.Remove(0, _output.Length - 8000);
                }
            }
        }

        private string Tail(int length)
        {
            lock (_output)
            {
                string text = _output.ToString().Trim();
                if (text.Length > length) text = text.Substring(text.Length - length);
                return string.IsNullOrEmpty(text) ? "Ayrıntı yok." : text;
            }
        }

        protected override void ExitThreadCore()
        {
            if (_timer != null)
            {
                _timer.Stop();
                _timer.Dispose();
                _timer = null;
            }

            if (_windowSeen) Program.KillTree(_browser);
            _browser = null;

            Program.KillTree(_server);
            _server = null;

            try
            {
                if (File.Exists(_runtimeFile)) File.Delete(_runtimeFile);
            }
            catch { }

            if (_tray != null)
            {
                _tray.Visible = false;
                _tray.Dispose();
                _tray = null;
            }

            base.ExitThreadCore();
        }
    }
}