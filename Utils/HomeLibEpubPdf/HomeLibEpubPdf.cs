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
        int formulas = 0;
        if ((args.Length != 3 && args.Length != 4) || !Uri.TryCreate(args[0], UriKind.Absolute, out viewer)
            || !Uri.TryCreate(args[1], UriKind.Absolute, out allowed)
            || allowed.Scheme != "http" || allowed.Host != "127.0.0.1"
            || !string.IsNullOrEmpty(allowed.UserInfo + allowed.Query + allowed.Fragment)
            || !allowed.AbsolutePath.EndsWith("/", StringComparison.Ordinal)
            || !long.TryParse(args[2], NumberStyles.None, CultureInfo.InvariantCulture, out maximum)
            || maximum <= 0)
            return 1;
        if (args.Length == 4 && (!int.TryParse(args[3], NumberStyles.None, CultureInfo.InvariantCulture, out formulas)
            || formulas < 1 || formulas > 256))
            return 1;
        if (viewer.GetLeftPart(UriPartial.Path) != allowed.AbsoluteUri + (formulas > 0 ? "viewer/math.html" : "viewer/index.html"))
            return 1;

        int result = 1;
        using (var host = new Form { ShowInTaskbar = false, ClientSize = new Size(900, 1200) })
        {
            var handle = host.Handle;
            host.BeginInvoke(new Action(async () =>
            {
                try
                {
                    await Render(handle, viewer, allowed, maximum, formulas);
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

    static async Task Render(IntPtr handle, Uri viewer, Uri allowed, long maximum, int formulas)
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
        string profile = Environment.GetEnvironmentVariable("WEBVIEW2_USER_DATA_FOLDER") ?? "browser-profile";
        var environment = await CoreWebView2Environment.CreateAsync(null, Path.GetFullPath(profile), options);
        CheckCancellation();
        var controller = await environment.CreateCoreWebView2ControllerAsync(handle);
        Process engine = null;
        bool controlledEngine = false;
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
            controlledEngine = true;

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
                bool allowedResource = formulas > 0 ? request.Uri == viewer.AbsoluteUri :
                    (request.Uri.StartsWith(prefix, StringComparison.Ordinal) || request.Uri.StartsWith("data:", StringComparison.Ordinal)
                    || request.Uri.StartsWith("blob:" + origin + "/", StringComparison.Ordinal));
                if (request.Method != "GET" || !allowedResource)
                    e.Response = environment.CreateWebResourceResponse(null, 403, "Blocked", "");
            };
            CheckCancellation();
            if (formulas > 0)
                await WriteMath(web, viewer.AbsoluteUri, formulas, maximum);
            else
            {
                web.Navigate(viewer.AbsoluteUri);
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
                    {
                        if (!engine.WaitForExit(4000) && formulas > 0 && controlledEngine)
                        {
                            try { engine.Kill(); }
                            catch (InvalidOperationException) { /* Already exited. */ }
                            engine.WaitForExit(4000);
                        }
                    }
            }
        }
    }

    static async Task WriteMath(CoreWebView2 web, string viewer, int formulas, long maximum)
    {
        await web.CallDevToolsProtocolMethodAsync("Emulation.setDeviceMetricsOverride",
            "{\"width\":1200,\"height\":900,\"deviceScaleFactor\":1,\"mobile\":false}");
        web.Navigate(viewer);
        var deadline = Stopwatch.StartNew();
        string positions = "null";
        while (positions == "null" && deadline.ElapsedMilliseconds < 10000)
        {
            CheckCancellation();
            await Task.Delay(50);
            positions = await web.ExecuteScriptAsync(
                "document.readyState==='complete' && document.fonts.status==='loaded' " +
                "&& document.querySelectorAll('.formula').length ? Array.from(document.querySelectorAll('.formula'), box => { " +
                "const r=box.getBoundingClientRect(), x=Math.floor(r.left+scrollX), y=Math.floor(r.top+scrollY); " +
                "return {x,y,width:Math.ceil(r.right+scrollX)-x,height:Math.ceil(r.bottom+scrollY)-y}; }) : null");
        }
        var clips = Json.Deserialize<Dictionary<string, int>[]>(positions);
        if (clips == null || clips.Length != formulas)
            throw new InvalidDataException("Модуль не получил полный список формул.");
        for (int i = 0; i < clips.Length; i++)
        {
            CheckCancellation();
            var clip = clips[i];
            if (clip["width"] <= 4 || clip["height"] <= 4 || clip["width"] > 1100 || clip["height"] > 480)
                continue;
            clip["scale"] = 2;
            var image = Json.Deserialize<Dictionary<string, string>>(await web.CallDevToolsProtocolMethodAsync(
                "Page.captureScreenshot", "{\"format\":\"png\",\"captureBeyondViewport\":true,\"clip\":" + Json.Serialize(clip) + "}"));
            var bytes = Convert.FromBase64String(image["data"]);
            if (bytes.LongLength > maximum)
                throw new InvalidDataException("Изображения формул превысили предел конвертации.");
            maximum -= bytes.LongLength;
            using (var output = File.Open("formula-" + i.ToString("D4", CultureInfo.InvariantCulture) + ".png",
                FileMode.CreateNew, FileAccess.Write))
                output.Write(bytes, 0, bytes.Length);
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
