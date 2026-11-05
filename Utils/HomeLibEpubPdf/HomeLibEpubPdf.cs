using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using Microsoft.Web.WebView2.Core;

static class HomeLibEpubPdf
{
    const int Cancelled = 2;
    const int MissingRuntime = 3;
    static readonly JavaScriptSerializer Json = new JavaScriptSerializer();

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool QueryFullProcessImageName(IntPtr process, int flags, StringBuilder path, ref int size);

    [STAThread]
    static int Main(string[] args)
    {
        Console.OutputEncoding = new UTF8Encoding(false);
        Uri allowed;
        Uri viewer;
        long maximum;
        if (args.Length != 3 || !Uri.TryCreate(args[0], UriKind.Absolute, out viewer)
            || !Uri.TryCreate(args[1], UriKind.Absolute, out allowed)
            || allowed.Scheme != "http" || allowed.Host != "127.0.0.1"
            || !string.IsNullOrEmpty(allowed.UserInfo + allowed.Query + allowed.Fragment)
            || !allowed.AbsolutePath.EndsWith("/", StringComparison.Ordinal)
            || viewer.GetLeftPart(UriPartial.Path) != allowed.AbsoluteUri + "viewer/index.html"
            || !long.TryParse(args[2], NumberStyles.None, CultureInfo.InvariantCulture, out maximum)
            || maximum <= 0)
            return 1;

        int result = 1;
        using (var host = new Form { ShowInTaskbar = false, ClientSize = new Size(900, 1200) })
        {
            var handle = host.Handle;
            host.BeginInvoke(new Action(async () =>
            {
                try
                {
                    await Print(handle, viewer.AbsoluteUri, allowed, maximum);
                    result = 0;
                }
                catch (OperationCanceledException)
                {
                    result = Cancelled;
                }
                catch (WebView2RuntimeNotFoundException)
                {
                    result = MissingRuntime;
                }
                catch (Exception error)
                {
                    Console.Error.WriteLine(error.Message);
                }
                finally
                {
                    Application.ExitThread();
                }
            }));
            Application.Run();
        }
        return result;
    }

    static void CheckCancellation()
    {
        if (File.Exists("cancel-epub-pdf"))
            throw new OperationCanceledException();
    }

    static async Task Print(IntPtr handle, string viewer, Uri allowed, long maximum)
    {
        CheckCancellation();
        var origin = allowed.GetLeftPart(UriPartial.Authority);
        var prefix = allowed.AbsoluteUri;
        var options = new CoreWebView2EnvironmentOptions(
            "--disable-background-networking --disable-background-timer-throttling --disable-renderer-backgrounding " +
            "--disable-backgrounding-occluded-windows --disable-component-update --disable-extensions --disable-quic " +
            "--proxy-server=" + origin + " --proxy-bypass-list=<-loopback>;" + allowed.Authority);
        options.ReleaseChannels = CoreWebView2ReleaseChannels.Stable;
        options.ExclusiveUserDataFolderAccess = true;
        var environment = await CoreWebView2Environment.CreateAsync(null, Path.GetFullPath("browser-profile"), options);
        CheckCancellation();
        var controller = await environment.CreateCoreWebView2ControllerAsync(handle);
        Process engine = null;
        try
        {
            var web = controller.CoreWebView2;
            engine = Process.GetProcessById((int)web.BrowserProcessId);
            var executable = new StringBuilder(4096);
            int length = executable.Capacity;
            if (!QueryFullProcessImageName(engine.Handle, 0, executable, ref length)
                || !string.Equals(Path.GetFileName(executable.ToString()), "msedgewebview2.exe",
                    StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("Ожидалась среда Microsoft WebView2 Runtime.");

            controller.Bounds = new Rectangle(0, 0, 900, 1200);
            controller.IsVisible = true;
            web.Settings.IsWebMessageEnabled = false;
            web.Settings.AreHostObjectsAllowed = false;
            web.Settings.AreDefaultScriptDialogsEnabled = false;
            web.NewWindowRequested += (sender, e) => { e.Handled = true; };
            web.PermissionRequested += (sender, e) => { e.State = CoreWebView2PermissionState.Deny; };
            web.DownloadStarting += (sender, e) => { e.Cancel = true; };
            web.NavigationStarting += (sender, e) => { e.Cancel = !e.Uri.StartsWith(prefix, StringComparison.Ordinal); };
            web.FrameNavigationStarting += (sender, e) => { e.Cancel = !e.Uri.StartsWith(prefix, StringComparison.Ordinal); };
            web.AddWebResourceRequestedFilter("*", CoreWebView2WebResourceContext.All, CoreWebView2WebResourceRequestSourceKinds.All);
            web.WebResourceRequested += (sender, e) =>
            {
                var request = e.Request;
                if (request.Method != "GET" || !(request.Uri.StartsWith(prefix, StringComparison.Ordinal)
                    || request.Uri.StartsWith("data:", StringComparison.Ordinal)
                    || request.Uri.StartsWith("blob:" + origin + "/", StringComparison.Ordinal)))
                    e.Response = environment.CreateWebResourceResponse(null, 403, "Blocked", "");
            };
            CheckCancellation();
            web.Navigate(viewer);
            while (await web.ExecuteScriptAsync("window.coreViewer?.readyState") != "\"complete\"")
            {
                CheckCancellation();
                var failure = Json.Deserialize<string>(await web.ExecuteScriptAsync("window.bookLoadFailed"));
                if (!string.IsNullOrEmpty(failure))
                    throw new InvalidDataException("Не удалось обработать содержимое EPUB. " +
                        failure.Substring(0, Math.Min(failure.Length, 250)));
                await Task.Delay(100);
            }
            if (await web.ExecuteScriptAsync("document.querySelectorAll('[data-vivliostyle-page-container]').length") == "0")
                throw new InvalidDataException("Модуль вёрстки не создал ни одной страницы PDF.");
            await CollectOutline(web);
            await WritePdf(web, maximum);
        }
        finally
        {
            try
            {
                controller.Close();
            }
            finally
            {
                if (engine != null)
                    using (engine)
                        engine.WaitForExit(4000);
            }
        }
    }

    static async Task CollectOutline(CoreWebView2 web)
    {
        // Showing the EPUB TOC before printing lets Chromium emit its link destinations.
        await web.ExecuteScriptAsync("window.coreViewer.showTOC(true)");
        var timer = Stopwatch.StartNew();
        while (timer.ElapsedMilliseconds < 3000)
        {
            CheckCancellation();
            var outline = await web.ExecuteScriptAsync("window.printOutline");
            if (outline != "null")
            {
                if (outline.Length <= 4 * 1024 * 1024)
                    File.WriteAllText("printed-toc.json", outline, new UTF8Encoding(false));
                return;
            }
            await Task.Delay(60);
        }
        await web.ExecuteScriptAsync("window.coreViewer.showTOC(false)");
    }

    static async Task WritePdf(CoreWebView2 web, long maximum)
    {
        CheckCancellation();
        var print = await web.CallDevToolsProtocolMethodAsync("Page.printToPDF",
            "{\"printBackground\":true,\"preferCSSPageSize\":true,\"generateTaggedPDF\":true,\"generateDocumentOutline\":true," +
            "\"marginTop\":0,\"marginBottom\":0,\"marginLeft\":0,\"marginRight\":0,\"transferMode\":\"ReturnAsStream\"}");
        var handle = Json.Serialize(Json.Deserialize<Dictionary<string, object>>(print)["stream"]);
        var parameters = "{\"handle\":" + handle + ",\"size\":262144}";
        using (var output = File.Open("rendered.pdf", FileMode.CreateNew, FileAccess.Write))
        {
            while (true)
            {
                CheckCancellation();
                var result = Json.Deserialize<Dictionary<string, object>>(
                    await web.CallDevToolsProtocolMethodAsync("IO.read", parameters));
                var data = (string)result["data"];
                object encoded;
                var bytes = result.TryGetValue("base64Encoded", out encoded) && (bool)encoded
                    ? Convert.FromBase64String(data) : Encoding.UTF8.GetBytes(data);
                if (bytes.LongLength > maximum - output.Length)
                    throw new InvalidDataException("Размер PDF превысил предел конвертации.");
                output.Write(bytes, 0, bytes.Length);
                if ((bool)result["eof"])
                    break;
            }
        }
        await web.CallDevToolsProtocolMethodAsync("IO.close", "{\"handle\":" + handle + "}");
    }
}
