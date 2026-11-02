using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Reflection;
using System.Text;
using System.Threading;
using System.Windows.Forms;

namespace EbmFanScan
{
    internal static class Program
    {
        private const string MutexName = "Local\\EBMFanScanLauncher";

        [STAThread]
        private static void Main(string[] args)
        {
            bool createdNew;
            using (var mutex = new Mutex(true, MutexName, out createdNew))
            {
                string baseDir = AppDomain.CurrentDomain.BaseDirectory;
                string installDir = ResolveInstallDir(baseDir);

                if (!createdNew)
                {
                    string existingUrl = ReadRuntimeUrl(installDir);
                    if (!string.IsNullOrEmpty(existingUrl))
                    {
                        OpenBrowser(existingUrl);
                    }
                    else
                    {
                        MessageBox.Show(
                            "Fan Modbus zaten çalışıyor.",
                            "Fan Modbus",
                            MessageBoxButtons.OK,
                            MessageBoxIcon.Information);
                    }
                    return;
                }

                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);

                try
                {
                    EnsureRuntimeFiles(installDir);
                    bool noBrowser = args.Any(a => string.Equals(a, "--no-browser", StringComparison.OrdinalIgnoreCase));
                    Application.Run(new MainForm(installDir, noBrowser));
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

        public static void OpenBrowser(string url)
        {
            try
            {
                string edge = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86),
                    @"Microsoft\Edge\Application\msedge.exe");
                if (File.Exists(edge))
                {
                    Process.Start(new ProcessStartInfo(edge, "--app=" + url + " --window-size=1500,1000")
                    {
                        UseShellExecute = false
                    });
                    return;
                }

                string chrome = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
                    @"Google\Chrome\Application\chrome.exe");
                if (File.Exists(chrome))
                {
                    Process.Start(new ProcessStartInfo(chrome, "--app=" + url + " --window-size=1500,1000")
                    {
                        UseShellExecute = false
                    });
                    return;
                }

                Process.Start(url);
            }
            catch
            {
                try { Process.Start(url); } catch { }
            }
        }
    }

    internal sealed class MainForm : Form
    {
        private readonly string _installDir;
        private readonly bool _noBrowser;
        private readonly string _runtimeFile;
        private readonly StringBuilder _output = new StringBuilder();

        private Process _server;
        private System.Windows.Forms.Timer _timer;
        private DateTime _startedAt;
        private string _url;

        private Label _status;
        private LinkLabel _link;
        private Button _openButton;

        public MainForm(string installDir, bool noBrowser)
        {
            _installDir = installDir;
            _noBrowser = noBrowser;
            _runtimeFile = Path.Combine(installDir, "runtime_url.txt");

            Text = "Fan Modbus";
            ClientSize = new Size(500, 268);
            FormBorderStyle = FormBorderStyle.FixedSingle;
            MaximizeBox = false;
            StartPosition = FormStartPosition.CenterScreen;
            Font = new Font("Segoe UI", 9F, FontStyle.Regular, GraphicsUnit.Point);
            BackColor = Color.FromArgb(11, 18, 32);
            ForeColor = Color.FromArgb(230, 238, 252);

            var title = new Label();
            title.Text = "Fan Modbus";
            title.Font = new Font("Segoe UI", 18F, FontStyle.Bold, GraphicsUnit.Point);
            title.ForeColor = Color.FromArgb(103, 232, 249);
            title.AutoSize = true;
            title.Location = new Point(22, 18);
            Controls.Add(title);

            var subtitle = new Label();
            subtitle.Text = "Modbus gateway cihaz bulucu";
            subtitle.ForeColor = Color.FromArgb(147, 164, 195);
            subtitle.AutoSize = true;
            subtitle.Location = new Point(25, 54);
            Controls.Add(subtitle);

            _status = new Label();
            _status.Text = "Sunucu başlatılıyor…";
            _status.AutoSize = false;
            _status.AutoEllipsis = true;
            _status.Size = new Size(455, 42);
            _status.Location = new Point(25, 88);
            _status.ForeColor = Color.FromArgb(230, 238, 252);
            Controls.Add(_status);

            _link = new LinkLabel();
            _link.Text = "";
            _link.AutoSize = false;
            _link.Size = new Size(455, 22);
            _link.Location = new Point(25, 130);
            _link.LinkColor = Color.FromArgb(103, 232, 249);
            _link.LinkClicked += delegate
            {
                if (!string.IsNullOrEmpty(_url)) Program.OpenBrowser(_url);
            };
            Controls.Add(_link);

            _openButton = new Button();
            _openButton.Text = "Arayüzü Aç";
            _openButton.Enabled = false;
            _openButton.Size = new Size(120, 34);
            _openButton.Location = new Point(25, 172);
            _openButton.Click += delegate
            {
                if (!string.IsNullOrEmpty(_url)) Program.OpenBrowser(_url);
            };
            Controls.Add(_openButton);

            var folderButton = new Button();
            folderButton.Text = "Klasörü Aç";
            folderButton.Size = new Size(110, 34);
            folderButton.Location = new Point(155, 172);
            folderButton.Click += delegate
            {
                try { Process.Start("explorer.exe", "\"" + _installDir + "\""); } catch { }
            };
            Controls.Add(folderButton);

            var stopButton = new Button();
            stopButton.Text = "Durdur ve Kapat";
            stopButton.Size = new Size(150, 34);
            stopButton.Location = new Point(325, 172);
            stopButton.Click += delegate
            {
                StopServer();
                Close();
            };
            Controls.Add(stopButton);

            var note = new Label();
            note.Text = "Bu pencere açıkken program çalışır. Tarayıcı penceresi kapansa bile sunucu açık kalır.";
            note.ForeColor = Color.FromArgb(120, 140, 170);
            note.AutoSize = false;
            note.Size = new Size(455, 36);
            note.Location = new Point(25, 218);
            Controls.Add(note);
        }

        protected override void OnShown(EventArgs e)
        {
            base.OnShown(e);
            StartServer();
        }

        protected override void OnFormClosing(FormClosingEventArgs e)
        {
            if (e.CloseReason == CloseReason.WindowsShutDown || e.CloseReason == CloseReason.TaskManagerClosing)
            {
                StopServer();
                base.OnFormClosing(e);
                return;
            }

            if (_server != null && !_server.HasExited)
            {
                DialogResult result = MessageBox.Show(
                    "Fan Modbus kapatılsın mı?\r\n\r\nEvet: sunucu durdurulur.\r\nHayır: pencere simge durumuna küçültülür.\r\nİptal: hiçbir şey yapılmaz.",
                    "Fan Modbus",
                    MessageBoxButtons.YesNoCancel,
                    MessageBoxIcon.Question);

                if (result == DialogResult.Cancel)
                {
                    e.Cancel = true;
                    return;
                }
                if (result == DialogResult.No)
                {
                    e.Cancel = true;
                    WindowState = FormWindowState.Minimized;
                    return;
                }
            }

            StopServer();
            base.OnFormClosing(e);
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
                SetStatus("start.ps1 bulunamadı: " + _installDir);
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
                SetStatus("Sunucu başlatılamadı: " + ex.Message);
                return;
            }

            _startedAt = DateTime.UtcNow;
            _timer = new System.Windows.Forms.Timer();
            _timer.Interval = 250;
            _timer.Tick += delegate { PollServer(); };
            _timer.Start();
        }

        private void PollServer()
        {
            if (_server != null && _server.HasExited)
            {
                if (_timer != null) _timer.Stop();
                SetStatus("Sunucu başlatılamadı.");
                MessageBox.Show(
                    "Sunucu başlatılamadı.\r\n\r\n" + Tail(900),
                    "Fan Modbus",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Error);
                return;
            }

            string url = Program.ReadRuntimeUrl(_installDir);
            if (!string.IsNullOrEmpty(url))
            {
                _url = url;
                if (_timer != null) _timer.Stop();
                _link.Text = url;
                _openButton.Enabled = true;
                SetStatus("Çalışıyor. Arayüz tarayıcıda açıldı.");
                if (!_noBrowser)
                {
                    Program.OpenBrowser(url);
                    WindowState = FormWindowState.Minimized;
                }
                return;
            }

            if ((DateTime.UtcNow - _startedAt).TotalSeconds > 30)
            {
                if (_timer != null) _timer.Stop();
                SetStatus("Sunucu 30 saniye içinde başlamadı.");
                MessageBox.Show(
                    "Sunucu 30 saniye içinde başlamadı.\r\n\r\n" + Tail(900),
                    "Fan Modbus",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Error);
            }
        }

        private void SetStatus(string text)
        {
            if (_status != null) _status.Text = text;
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

        private void StopServer()
        {
            if (_timer != null)
            {
                _timer.Stop();
                _timer.Dispose();
                _timer = null;
            }

            try
            {
                if (_server != null && !_server.HasExited)
                {
                    string taskkill = Path.Combine(
                        Environment.GetFolderPath(Environment.SpecialFolder.System),
                        "taskkill.exe");
                    Process.Start(new ProcessStartInfo(taskkill, "/PID " + _server.Id + " /T /F")
                    {
                        UseShellExecute = false,
                        CreateNoWindow = true
                    });
                    _server.WaitForExit(4000);
                }
            }
            catch { }
            finally
            {
                _server = null;
                try
                {
                    if (File.Exists(_runtimeFile)) File.Delete(_runtimeFile);
                }
                catch { }
            }
        }
    }
}
