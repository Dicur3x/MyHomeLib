// Test-only decoder substitute: copy a supplied page ZIP, or await cancellation.
using System;
using System.IO;
using System.Diagnostics;
using System.Threading;
class Fixture {
    static int Main(string[] args) {
        if (Path.GetFileName(args[1]).StartsWith("api-unavailable")) {
            Console.WriteLine("OPENXPS_API_UNAVAILABLE"); return 1;
        }
        if (Path.GetFileName(args[1]).StartsWith("wait")) {
            File.WriteAllText(args[1]+".pid",Process.GetCurrentProcess().Id.ToString());
            Thread.Sleep(90000);
        }
        File.Copy(args[1],args[2]); return 0;
    }
}
