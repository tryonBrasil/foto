using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Security.Principal;
using System.Windows.Forms;

[assembly: AssemblyTitle("Otimizador Gamer")]
[assembly: AssemblyProduct("Otimizador Gamer")]
[assembly: AssemblyCompany("Tryon Brasil")]
[assembly: AssemblyCopyright("Tryon Brasil")]
[assembly: AssemblyVersion("3.3.0.0")]
[assembly: AssemblyFileVersion("3.3.0.0")]

class Launcher
{
    [STAThread]
    static int Main(string[] args)
    {
        try
        {
            string extra = string.Join(" ", args);

            WindowsPrincipal pr = new WindowsPrincipal(WindowsIdentity.GetCurrent());
            if (!pr.IsInRole(WindowsBuiltInRole.Administrator))
            {
                ProcessStartInfo elev = new ProcessStartInfo(Assembly.GetExecutingAssembly().Location, extra);
                elev.UseShellExecute = true;
                elev.Verb = "runas";
                Process.Start(elev);
                return 0;
            }

            string dir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "OtimizadorGamer");
            Directory.CreateDirectory(dir);
            string ps1 = Path.Combine(dir, "OtimizadorGamer.ps1");

            using (Stream s = Assembly.GetExecutingAssembly().GetManifestResourceStream("OtimizadorGamer.ps1"))
            using (FileStream f = File.Create(ps1))
            {
                s.CopyTo(f);
            }

            ProcessStartInfo psi = new ProcessStartInfo("powershell.exe",
                ("-NoProfile -ExecutionPolicy Bypass -File \"" + ps1 + "\" " + extra).Trim());
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.EnvironmentVariables["OTIMIZADOR_EXE"] = Assembly.GetExecutingAssembly().Location;
            Process p = Process.Start(psi);
            p.WaitForExit();
            return p.ExitCode;
        }
        catch (Exception ex)
        {
            MessageBox.Show("Erro ao iniciar o Otimizador Gamer:\n" + ex.Message,
                "Otimizador Gamer", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }
}
