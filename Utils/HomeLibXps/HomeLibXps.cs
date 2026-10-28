// Copyright (c) 2026 MyHomeLib contributors. MIT; see ../../LICENSE.
// Render only the Windows XPS fixed-document subset, without a viewer or printer.
using System;
using System.IO;
using System.IO.Compression;
using System.IO.Packaging;
using System.Collections.Generic;
using System.Text.RegularExpressions;
using System.Xml;
using System.Windows;
using System.Windows.Documents;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Xps.Packaging;

internal static class HomeLibXps
{
    private const long MaxInput = 64L * 1024 * 1024, MaxTotal = 256L * 1024 * 1024;
    private const string XpsNamespace = "http://schemas.microsoft.com/xps/2005/06";
    private static readonly HashSet<string> StructureNodes = new HashSet<string>((
        "DocumentStructure DocumentStructure.Outline DocumentOutline OutlineEntry " +
        "Story StoryFragmentReference StoryFragments StoryFragment SectionStructure " +
        "ParagraphStructure FigureStructure NamedElement ListStructure ListItemStructure " +
        "TableStructure TableRowGroupStructure TableRowStructure TableCellStructure").Split(' '));
    private static readonly HashSet<string> Nodes = new HashSet<string>((
        "FixedDocumentSequence DocumentReference FixedDocument PageContent FixedPage Canvas Glyphs Path " +
        "FixedPage.Resources Canvas.Resources ResourceDictionary ResourceDictionary.MergedDictionaries " +
        "Path.Fill Path.Stroke Path.Data Path.Clip Path.RenderTransform Path.OpacityMask " +
        "Canvas.Clip Canvas.RenderTransform Canvas.OpacityMask Glyphs.Fill Glyphs.Clip Glyphs.RenderTransform Glyphs.OpacityMask " +
        "SolidColorBrush ImageBrush LinearGradientBrush RadialGradientBrush VisualBrush " +
        "ImageBrush.Transform LinearGradientBrush.Transform RadialGradientBrush.Transform VisualBrush.Transform " +
        "VisualBrush.Visual GradientStop LinearGradientBrush.GradientStops RadialGradientBrush.GradientStops " +
        "MatrixTransform PathGeometry PathGeometry.Transform PathGeometry.Figures PathFigure PathFigure.Segments " +
        "PolyLineSegment PolyBezierSegment PolyQuadraticBezierSegment ArcSegment " +
        "FixedPage.NavigateUri Canvas.NavigateUri Path.NavigateUri Glyphs.NavigateUri " +
        "FixedPage.LinkTargets LinkTarget").Split(new char[] {' '}, StringSplitOptions.RemoveEmptyEntries));

    [STAThread]
    private static int Main(string[] args)
    {
        string output = null; bool ownsOutput = false;
        try
        {
            if (args.Length == 1 && args[0] == "--version") { Console.WriteLine("HomeLibXps 1; Windows XPS/.NET Framework"); return 0; }
            if (args.Length == 3 && args[0] == "--image-pages") return ImagePages(args[1], args[2]);
            if (args.Length == 4 && args[0] == "--export-images") return ExportImages(args[1], args[2], args[3]);
            if (args.Length == 5 && args[0] == "--scan-images") return ScanImages(args[1], args[2], args[3], args[4]);
            if (args.Length != 2) throw new ArgumentException("Expected XPS and a new page ZIP.");
            string input = Path.GetFullPath(args[0]); output = Path.GetFullPath(args[1]);
            if (String.Equals(input, output, StringComparison.OrdinalIgnoreCase) || File.Exists(output)) throw new IOException("Output must be new.");
            long length = new FileInfo(input).Length;
            if (length <= 0 || length > MaxInput) throw new IOException("XPS size exceeds 64 MB or is empty.");
            Validate(input);
            using (var document = new XpsDocument(input, FileAccess.Read))
            {
                FixedDocumentSequence sequence = document.GetFixedDocumentSequence();
                if (sequence == null) throw new IOException("No fixed document sequence.");
                DocumentPaginator paginator = sequence.DocumentPaginator;
                paginator.ComputePageCount(); int count = paginator.PageCount;
                if (count <= 0 || count > 5000) throw new IOException("Invalid XPS page count.");
                using (var file = new FileStream(output, FileMode.CreateNew, FileAccess.ReadWrite, FileShare.None))
                {
                    ownsOutput = true; long total = 0;
                    using (var archive = new ZipArchive(file, ZipArchiveMode.Create, true))
                    for (int i = 0; i < count; i++)
                    using (DocumentPage page = paginator.GetPage(i))
                    {
                        double width = page.Size.Width, height = page.Size.Height;
                        if (Double.IsNaN(width) || Double.IsNaN(height) || Double.IsInfinity(width) || Double.IsInfinity(height) ||
                            width < 1 || height < 1 || width > 100000 || height > 100000) throw new IOException("Invalid XPS page dimensions.");
                        double scale = Math.Min(2.0, 1600.0 / Math.Max(width, height));
                        int pixelsX = Math.Max(1, (int)Math.Ceiling(width * scale)), pixelsY = Math.Max(1, (int)Math.Ceiling(height * scale));
                        var visual = new DrawingVisual();
                        using (DrawingContext drawing = visual.RenderOpen())
                        {
                            drawing.DrawRectangle(Brushes.White, null, new Rect(0, 0, width, height));
                            var brush = new VisualBrush(page.Visual) { Stretch = Stretch.Fill, AlignmentX = AlignmentX.Left, AlignmentY = AlignmentY.Top };
                            drawing.DrawRectangle(brush, null, new Rect(0, 0, width, height));
                        }
                        var bitmap = new RenderTargetBitmap(pixelsX, pixelsY, 96 * scale, 96 * scale, PixelFormats.Pbgra32);
                        bitmap.Render(visual);
                        var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(bitmap));
                        using (var bytes = new MemoryStream())
                        {
                            encoder.Save(bytes); total += bytes.Length;
                            if (bytes.Length > 16 * 1024 * 1024 || total > MaxTotal) throw new IOException("Rendered XPS exceeds the image limit.");
                            bytes.Position = 0;
                            var entry = archive.CreateEntry((i + 1).ToString("D5") + ".png", CompressionLevel.NoCompression);
                            using (Stream destination = entry.Open()) bytes.CopyTo(destination);
                        }
                        Console.WriteLine("PAGE " + (i + 1) + " " + count); Console.Out.Flush();
                    }
                    file.Flush(true);
                }
            }
            return 0;
        }
        catch (Exception error)
        {
            if (ownsOutput) { try { File.Delete(output); } catch { } }
            Console.Error.WriteLine("XPS: " + error.GetType().Name + ": " + error.Message); return 1;
        }
    }

    // Encode local book pictures in one bounded process. Never upscale a page.
    private static byte[] ExportImage(byte[] original, BitmapSource decoded, string profile)
    {
        if (profile == "high") return original;
        {
            BitmapSource source = decoded; int width = source.PixelWidth, height = source.PixelHeight;
            if (width <= 0 || height <= 0 || width > 16384 || height > 16384 || (long)width * height > 16777216)
                throw new IOException("Export image dimensions exceed the reader limit.");
            if (Math.Max(width, height) <= 512) return original;
            double edge = profile == "balanced" ? 2200 : 1600;
            double floor = profile == "economy" ? 0 : .85;
            double scale = Math.Min(1.0, Math.Max(floor, edge / Math.Max(width, height)));
            if (scale < 1.0)
            {
                var visual = new DrawingVisual(); RenderOptions.SetBitmapScalingMode(visual, BitmapScalingMode.HighQuality);
                int x = Math.Max(1, (int)Math.Round(width * scale)), y = Math.Max(1, (int)Math.Round(height * scale));
                using (DrawingContext drawing = visual.RenderOpen()) drawing.DrawImage(source, new Rect(0, 0, x, y));
                var resized = new RenderTargetBitmap(x, y, 96, 96, PixelFormats.Pbgra32); resized.Render(visual); source = resized;
                width = x; height = y;
            }
            // Preserve transparency and color. Neutral scans can use an eight-bit
            // gray plane; monochrome PNG often beats JPEG without losing any detail.
            var rgba = new FormatConvertedBitmap(source, PixelFormats.Bgra32, null, 0);
            byte[] pixels = new byte[checked(width * height * 4)]; rgba.CopyPixels(pixels, width * 4, 0);
            bool alpha = false, gray = true; int colored = 0, paperOrInk = 0;
            for (int at = 0; at < pixels.Length; at += 4)
            {
                if (pixels[at+3] != 255) alpha = true;
                if (pixels[at] != pixels[at+1] || pixels[at] != pixels[at+2]) gray = false;
                int low = Math.Min(pixels[at], Math.Min(pixels[at+1], pixels[at+2]));
                int high = Math.Max(pixels[at], Math.Max(pixels[at+1], pixels[at+2]));
                if (high - low > 12) colored++;
                int luminance = (pixels[at]*29 + pixels[at+1]*150 + pixels[at+2]*77) >> 8;
                if (luminance < 80 || luminance > 210) paperOrInk++;
            }
            BitmapSource encoded = source;
            if (!alpha) encoded = new FormatConvertedBitmap(source, gray ? PixelFormats.Gray8 : PixelFormats.Bgr24, null, 0);
            byte[] best = original; bool[] textRows=null;
            if (profile == "economy" && !alpha && colored == 0)
            {
                // A page made of many separated short ink bands is text, rather
                // than a photograph. Use a one-bit PNG only for that strict case;
                // faint print, tables with long rules and pictures keep gray/color.
                int bands=0, run=0, longest=0; bool[] rows=new bool[height];
                for (int y=0;y<height;y++)
                {
                    int ink=0;
                    for(int x=width/12;x<width-width/12;x++)
                    {
                        int at=(y*width+x)*4;
                        if(((pixels[at]*29+pixels[at+1]*150+pixels[at+2]*77)>>8)<180) ink++;
                    }
                    if(ink>Math.Max(3,width/160)) run++;
                    else if(run>0)
                    {
                        bands++; longest=Math.Max(longest,run);
                        if(run<=Math.Max(32,height/25)) for(int row=y-run;row<y;row++) rows[row]=true;
                        run=0;
                    }
                }
                if(run>0)
                {
                    bands++; longest=Math.Max(longest,run);
                    if(run<=Math.Max(32,height/25)) for(int row=height-run;row<height;row++) rows[row]=true;
                }
                if(bands>=12) textRows=rows;
                if(bands>=12 && longest<=Math.Max(32,height/25))
                {
                    int stride=(width+7)/8; byte[] packed=new byte[checked(stride*height)];
                    for(int y=0;y<height;y++) for(int x=0;x<width;x++)
                    {
                        int at=(y*width+x)*4;
                        if(((pixels[at]*29+pixels[at+1]*150+pixels[at+2]*77)>>8)>=180)
                            packed[y*stride+x/8]|=(byte)(128>>(x&7));
                    }
                    var bitonal=BitmapSource.Create(width,height,96,96,PixelFormats.Indexed1,
                        new BitmapPalette(new Color[]{Colors.Black,Colors.White}),packed,stride);
                    var png=new PngBitmapEncoder(); png.Frames.Add(BitmapFrame.Create(bitonal));
                    using(var bytes=new MemoryStream()) { png.Save(bytes); if(bytes.Length<best.Length) best=bytes.ToArray(); }
                }
            }
            // Text scans waste most of their bytes on nearly white paper noise.
            // Keep four gray levels and every stroke at the chosen resolution;
            // photographs and colored pages retain the ordinary color encoder.
            if (profile == "economy" && !alpha && colored == 0 && paperOrInk >= width*height*.90)
            {
                int stride = (width+3)/4; byte[] packed = new byte[checked(stride*height)];
                for (int y=0; y<height; y++) for (int x=0; x<width; x++)
                {
                    int at=(y*width+x)*4;
                    int value=(pixels[at]*29+pixels[at+1]*150+pixels[at+2]*77)>>8;
                    int level=value<85 ? 0 : value<155 ? 1 : value<220 ? 2 : 3;
                    if(textRows!=null && textRows[y]) level=value<180 ? 0 : 3;
                    packed[y*stride+x/4]|=(byte)(level<<(6-2*(x&3)));
                }
                var colors = new List<Color>();
                for (int level=0; level<4; level++) colors.Add(Color.FromRgb((byte)(level*85),(byte)(level*85),(byte)(level*85)));
                BitmapSource textScan=BitmapSource.Create(width,height,96,96,PixelFormats.Indexed2,new BitmapPalette(colors),packed,stride);
                var png = new PngBitmapEncoder(); png.Frames.Add(BitmapFrame.Create(textScan));
                using (var bytes=new MemoryStream()) { png.Save(bytes); if(bytes.Length<best.Length) best=bytes.ToArray(); }
            }
            if (alpha || original[0] != 255 || original[1] != 216)
            {
                var png = new PngBitmapEncoder(); png.Frames.Add(BitmapFrame.Create(encoded));
                using (var bytes = new MemoryStream()) { png.Save(bytes); if (bytes.Length < best.Length) best = bytes.ToArray(); }
            }
            if (!alpha)
            {
                var jpeg = new JpegBitmapEncoder { QualityLevel = profile == "balanced" ? 60 : 40 };
                jpeg.Frames.Add(BitmapFrame.Create(encoded));
                using (var bytes = new MemoryStream()) { jpeg.Save(bytes); if (bytes.Length < best.Length) best = bytes.ToArray(); }
            }
            return best;
        }
    }

    private static int ExportImages(string source, string destination, string profile)
    {
        if (profile != "high" && profile != "balanced" && profile != "economy" && profile != "estimate")
            throw new ArgumentException("Unknown export image profile.");
        string input = Path.GetFullPath(source), output = Path.GetFullPath(destination); bool owns = false;
        if (String.Equals(input, output, StringComparison.OrdinalIgnoreCase) || File.Exists(output)) throw new IOException("Output must be new.");
        if (new FileInfo(input).Length > MaxTotal) throw new IOException("Export images exceed 256 MB.");
        try
        {
            using (var inputFile = File.OpenRead(input))
            using (var archive = new ZipArchive(inputFile, ZipArchiveMode.Read))
            using (var outputFile = new FileStream(output, FileMode.CreateNew, FileAccess.ReadWrite, FileShare.None))
            {
                owns = true; long total = 0; int index = 0;
                if (archive.Entries.Count == 0 || archive.Entries.Count > (profile == "estimate" ? 9 : 5000)) throw new IOException("Invalid image count.");
                using (var result = new ZipArchive(outputFile, ZipArchiveMode.Create, true))
                foreach (var entry in archive.Entries)
                {
                    if (entry.FullName != index.ToString("D5") || entry.Length <= 0 || entry.Length > 16 * 1024 * 1024 || (total += entry.Length) > MaxTotal)
                        throw new IOException("Invalid export image entry.");
                    byte[] data;
                    using (Stream image = entry.Open()) using (var bytes = new MemoryStream()) { image.CopyTo(bytes); data = bytes.ToArray(); }
                    string[] profiles = new string[] { "high", "balanced", "economy" };
                    byte[] previous = data;
                    // Keep quality/size choices monotonic: a compact profile may
                    // reuse a smaller, clearer result from the previous profile.
                    using (var imageSource = new MemoryStream(data, false))
                    {
                        BitmapDecoder decoder = BitmapDecoder.Create(imageSource, BitmapCreateOptions.PreservePixelFormat, BitmapCacheOption.None);
                        if (decoder.Frames.Count != 1) throw new IOException("Expected a single raster resource.");
                        BitmapFrame frame = decoder.Frames[0];
                        if (frame.PixelWidth <= 0 || frame.PixelHeight <= 0 || frame.PixelWidth > 16384 || frame.PixelHeight > 16384 ||
                            (long)frame.PixelWidth * frame.PixelHeight > 16777216) throw new IOException("Invalid export image dimensions.");
                        bool keepMetadata = PreserveExportMetadata(frame, data);
                        foreach (string choice in profiles)
                        {
                            byte[] encoded = keepMetadata ? data : ExportImage(data, frame, choice);
                            if (previous.Length < encoded.Length) encoded = previous;
                            previous = encoded;
                            if (profile == "estimate" || choice == profile)
                                using (Stream target = result.CreateEntry(choice + "/" + entry.FullName, CompressionLevel.NoCompression).Open()) target.Write(encoded, 0, encoded.Length);
                            if (profile == choice) break;
                        }
                    }
                    index++; Console.WriteLine("IMAGE " + index + " " + archive.Entries.Count); Console.Out.Flush();
                }
                outputFile.Flush(true);
            }
            return 0;
        }
        catch { if (owns) { try { File.Delete(output); } catch { } } throw; }
    }

    private static int ScanOrientation(BitmapFrame frame, byte[] data)
    {
        var metadata=frame.Metadata as BitmapMetadata;
        if(metadata==null || data.Length<2 || data[0]!=255 || data[1]!=216) return 1;
        object orientation=metadata.GetQuery("/app1/ifd/{ushort=274}");
        int value=orientation==null ? 1 : Convert.ToInt32(orientation);
        if(value<1 || value>8) throw new IOException("Invalid scan EXIF orientation.");
        return value;
    }

    private static bool PreserveExportMetadata(BitmapFrame frame, byte[] data)
    {
        if(frame.ColorContexts!=null && frame.ColorContexts.Count!=0) return true;
        try { return ScanOrientation(frame,data)!=1; }
        catch(NotSupportedException) { return true; }
    }

    private static BitmapSource OrientedScan(BitmapFrame frame, byte[] data)
    {
        int orientation=ScanOrientation(frame,data);
        Matrix transform=Matrix.Identity;
        switch(orientation)
        {
            case 2: transform=new Matrix(-1,0,0,1,0,0); break;
            case 3: transform=new Matrix(-1,0,0,-1,0,0); break;
            case 4: transform=new Matrix(1,0,0,-1,0,0); break;
            case 5: transform=new Matrix(0,1,1,0,0,0); break;
            case 6: transform=new Matrix(0,1,-1,0,0,0); break;
            case 7: transform=new Matrix(0,-1,-1,0,0,0); break;
            case 8: transform=new Matrix(0,-1,1,0,0,0); break;
        }
        return orientation==1 ? (BitmapSource)frame : new TransformedBitmap(frame,new MatrixTransform(transform));
    }

    private static byte[] ScanPng(BitmapSource source, BitmapFrame original)
    {
        // Cropping removes EXIF orientation after applying it to the pixels,
        // while retaining an individual color profile in the resulting PNG.
        var png=new PngBitmapEncoder(); png.Frames.Add(BitmapFrame.Create(source,null,null,original.ColorContexts));
        using(var bytes=new MemoryStream()) { png.Save(bytes); return bytes.ToArray(); }
    }

    private static bool ScanInkOnBothSides(double[] ink, int cut, int width)
    {
        int reach=Math.Max(12,width/6), gap=Math.Max(2,width/100);
        double left=0,right=0; int leftCount=0,rightCount=0;
        for(int x=Math.Max(0,cut-reach);x<cut-gap;x++) { left+=ink[x]; leftCount++; }
        for(int x=cut+gap;x<Math.Min(width,cut+reach);x++) { right+=ink[x]; rightCount++; }
        return leftCount>0 && rightCount>0 && left/leftCount>.025 && right/rightCount>.025;
    }

    private static int AutomaticScanCut(BitmapSource page, out string method)
    {
        method="uncertain";
        // Analyze a small copy only; crop the original pixels afterwards. A new
        // boundary is found for every spread, so a moving spine is not fixed to
        // the first page's position. Never guess through an occupied center.
        double scale=Math.Min(1,Math.Min(800.0/page.PixelWidth,600.0/page.PixelHeight));
        BitmapSource sample=scale<1 ? new TransformedBitmap(page,new ScaleTransform(scale,scale)) : page;
        var gray=new FormatConvertedBitmap(sample,PixelFormats.Gray8,null,0);
        int width=gray.PixelWidth,height=gray.PixelHeight;
        byte[] pixels=new byte[checked(width*height)]; gray.CopyPixels(pixels,width,0);
        int top=height/12,bottom=height-height/12,rows=bottom-top;
        if(width<40 || rows<30) return 0;
        int[] histogram=new int[256];
        for(int y=top;y<bottom;y++) for(int x=0;x<width;x++) histogram[pixels[y*width+x]]++;
        int paper=0,seen=0,target=(int)((long)width*rows*.85);
        while(paper<255 && (seen+=histogram[paper])<target) paper++;
        if(paper<160) return 0;
        int threshold=Math.Max(60,paper-45);
        double[] ink=new double[width],mean=new double[width];
        for(int x=0;x<width;x++)
        {
            int dark=0,sum=0;
            for(int y=top;y<bottom;y++) { int value=pixels[y*width+x]; sum+=value; if(value<threshold) dark++; }
            ink[x]=(double)dark/rows; mean[x]=(double)sum/rows;
        }
        int first=width/3,last=width*2/3,neighbor=Math.Max(6,width/40),best=0;
        double bestScore=0;
        // A crease or its shadow crosses most rows and is darker than the
        // nearby paper. Prefer this visible divider over a merely blank gap.
        for(int x=first;x<last;)
        {
            int start=x;
            while(x<last && ink[x]>=.72 && (mean[x-neighbor]+mean[x+neighbor])*.5-mean[x]>=22) x++;
            int length=x-start;
            if(length>0 && length<=width/12)
            {
                int cut=start+length/2;
                double contrast=(mean[cut-neighbor]+mean[cut+neighbor])*.5-mean[cut];
                double score=contrast/255+ink[cut]-Math.Abs((double)cut/width-.5)*.1;
                if(score>bestScore && ScanInkOnBothSides(ink,cut,width)) { best=cut; bestScore=score; }
            }
            if(x==start) x++;
        }
        if(best>0) { method="crease"; return Math.Max(1,Math.Min(page.PixelWidth-1,(int)Math.Round((double)best*page.PixelWidth/width))); }
        // Otherwise use the middle of a sufficiently wide, nearly empty paper
        // strip, with actual page content on both sides. Portrait pages and
        // uncertain full-width illustrations are kept whole in automatic mode.
        bestScore=0;
        for(int x=first;x<last;)
        {
            int start=x;
            while(x<last && ink[x]<=.02 && mean[x]>=paper-18) x++;
            int length=x-start,cut=start+length/2;
            if(length>=Math.Max(3,width/100) && length<=width/5 && ScanInkOnBothSides(ink,cut,width))
            {
                double score=(double)length/width-Math.Abs((double)cut/width-.5)*.03;
                if(score>bestScore) { best=cut; bestScore=score; }
            }
            if(x==start) x++;
        }
        if(bestScore>0) { method="gap"; return Math.Max(1,Math.Min(page.PixelWidth-1,(int)Math.Round((double)best*page.PixelWidth/width))); }
        return 0;
    }

    private static int ScanImages(string source, string destination, string profile, string layout)
    {
        if(profile!="original" && profile!="high" && profile!="balanced" && profile!="economy" && profile!="estimate")
            throw new ArgumentException("Unknown scan quality.");
        if(layout!="keep" && layout!="split" && layout!="auto") throw new ArgumentException("Unknown scan layout.");
        string input=Path.GetFullPath(source),output=Path.GetFullPath(destination); bool owns=false;
        if(String.Equals(input,output,StringComparison.OrdinalIgnoreCase) || File.Exists(output)) throw new IOException("Output must be new.");
        if(new FileInfo(input).Length>MaxTotal) throw new IOException("Scan batch exceeds 256 MB.");
        try
        {
            using(var incoming=File.OpenRead(input)) using(var archive=new ZipArchive(incoming,ZipArchiveMode.Read))
            using(var file=new FileStream(output,FileMode.CreateNew,FileAccess.ReadWrite,FileShare.None))
            {
                owns=true; long total=0; int index=0;
                if(archive.Entries.Count==0 || archive.Entries.Count>12) throw new IOException("Invalid scan batch.");
                using(var result=new ZipArchive(file,ZipArchiveMode.Create,true)) foreach(var entry in archive.Entries)
                {
                    if(entry.FullName!=index.ToString("D5") || entry.Length<=0 || entry.Length>16*1024*1024 || (total+=entry.Length)>MaxTotal)
                        throw new IOException("Invalid scan entry.");
                    byte[] original;
                    using(var stream=entry.Open()) using(var bytes=new MemoryStream()) { stream.CopyTo(bytes); original=bytes.ToArray(); }
                    using(var stream=new MemoryStream(original,false))
                    {
                        var decoder=BitmapDecoder.Create(stream,BitmapCreateOptions.PreservePixelFormat,BitmapCacheOption.None);
                        if(decoder.Frames.Count!=1) throw new IOException("Expected a single scan page.");
                        BitmapFrame originalFrame=decoder.Frames[0];
                        BitmapSource frame=layout!="keep" ? OrientedScan(originalFrame,original) : originalFrame;
                        bool keepMetadata=PreserveExportMetadata(originalFrame,original);
                        int width=frame.PixelWidth,height=frame.PixelHeight;
                        if(width<1 || height<1 || width>16384 || height>16384 || (long)width*height>16777216)
                            throw new IOException("Scan dimensions exceed the reader limit.");
                        int cut=0; string boundary="center";
                        if(layout!="keep" && width>height*1.10)
                        {
                            cut=layout=="auto" ? AutomaticScanCut(frame,out boundary) : width/2;
                            Console.WriteLine(cut>0 ? "SCAN_SPLIT "+index+" "+cut+" "+width+" "+boundary : "SCAN_UNSPLIT "+index);
                        }
                        bool split=cut>0;
                        int parts=split ? 2 : 1;
                        for(int part=0;part<parts;part++)
                        {
                            BitmapSource page=frame; byte[] data=original;
                            if(split)
                            {
                                int left=part==0 ? 0 : cut, size=part==0 ? cut : width-cut;
                                page=new CroppedBitmap(frame,new Int32Rect(left,0,size,height)); data=ScanPng(page,originalFrame);
                            }
                            byte[] previous=data;
                            foreach(string choice in new string[]{"original","high","balanced","economy"})
                            {
                                byte[] encoded=(choice=="original" || keepMetadata) ? data : ExportImage(data,page,choice);
                                if(previous.Length<encoded.Length) encoded=previous;
                                previous=encoded;
                                if(encoded.Length>16*1024*1024) throw new IOException("Encoded scan page exceeds 16 MB.");
                                if(profile=="estimate" || choice==profile)
                                    using(var target=result.CreateEntry(choice+"/"+entry.FullName+"-"+part,CompressionLevel.NoCompression).Open())
                                        target.Write(encoded,0,encoded.Length);
                                if(choice==profile) break;
                            }
                        }
                    }
                    index++; Console.WriteLine("IMAGE "+index+" "+archive.Entries.Count); Console.Out.Flush();
                }
                file.Flush(true);
            }
            return 0;
        }
        catch { if(owns) { try { File.Delete(output); } catch { } } throw; }
    }

    private static int ImagePages(string source, string destination)
    {
        string input = Path.GetFullPath(source), output = Path.GetFullPath(destination); bool owns = false;
        if (String.Equals(input, output, StringComparison.OrdinalIgnoreCase) || File.Exists(output)) throw new IOException("Output must be new.");
        long length = new FileInfo(input).Length;
        if (length <= 0 || length > MaxTotal) throw new IOException("Image size exceeds 256 MB or is empty.");
        try
        {
            using (var stream = File.OpenRead(input))
            {
                int declaredFrames = ValidateTiffFrames(stream);
                stream.Position = 0;
                // Keep decoded pixels out of the decoder's per-frame cache:
                // a long TIFF otherwise retains every previous full-size page.
                BitmapDecoder decoder = BitmapDecoder.Create(stream, BitmapCreateOptions.PreservePixelFormat, BitmapCacheOption.None);
                int count = decoder.Frames.Count;
                if (count <= 0 || count > 5000) throw new IOException("Invalid image page count.");
                if (declaredFrames != 0 && count != declaredFrames) throw new IOException("TIFF decoder did not return every declared page.");
                using (var file = new FileStream(output, FileMode.CreateNew, FileAccess.ReadWrite, FileShare.None))
                {
                    owns = true; long total = 0;
                    using (var archive = new ZipArchive(file, ZipArchiveMode.Create, true))
                    for (int i = 0; i < count; i++)
                    {
                        BitmapFrame frame = decoder.Frames[i];
                        if (frame.PixelWidth <= 0 || frame.PixelHeight <= 0 || frame.PixelWidth > 16384 || frame.PixelHeight > 16384 ||
                            (long)frame.PixelWidth * frame.PixelHeight > 16777216) throw new IOException("Image page dimensions exceed the reader limit.");
                        var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(frame));
                        using (var bytes = new MemoryStream())
                        {
                            encoder.Save(bytes); total += bytes.Length;
                            if (bytes.Length > 16 * 1024 * 1024 || total > MaxTotal) throw new IOException("Image pages exceed the reader limit.");
                            bytes.Position = 0;
                            using (Stream target = archive.CreateEntry((i+1).ToString("D5") + ".png", CompressionLevel.NoCompression).Open()) bytes.CopyTo(target);
                        }
                        Console.WriteLine("PAGE " + (i+1) + " " + count); Console.Out.Flush();
                    }
                    file.Flush(true);
                }
            }
            return 0;
        }
        catch { if (owns) { try { File.Delete(output); } catch { } } throw; }
    }

    // WIC can silently stop at an invalid later IFD. Validate the complete page
    // chain first so that a truncated TIFF cannot become a successful short book.
    private static int ValidateTiffFrames(Stream stream)
    {
        byte[] header = new byte[8];
        if (stream.Read(header, 0, header.Length) != header.Length) return 0;
        bool little = header[0] == 73 && header[1] == 73;
        bool big = header[0] == 77 && header[1] == 77;
        if (!little && !big) return 0;
        Func<byte[], int, uint> u16 = (b, p) => little ? (uint)(b[p] | b[p+1] << 8) : (uint)(b[p] << 8 | b[p+1]);
        Func<byte[], int, uint> u32 = (b, p) => little ? (uint)(b[p] | b[p+1] << 8 | b[p+2] << 16 | b[p+3] << 24) : (uint)(b[p] << 24 | b[p+1] << 16 | b[p+2] << 8 | b[p+3]);
        if (u16(header, 2) != 42) throw new IOException("Unsupported TIFF header.");
        uint offset = u32(header, 4); var seen = new HashSet<uint>();
        byte[] word = new byte[4];
        while (offset != 0)
        {
            if (offset < 8 || offset > stream.Length - 2 || !seen.Add(offset) || seen.Count > 5000)
                throw new IOException("Invalid TIFF page directory.");
            stream.Position = offset;
            if (stream.Read(word, 0, 2) != 2) throw new IOException("Truncated TIFF page directory.");
            long next = offset + 2L + 12L * u16(word, 0);
            if (next > stream.Length - 4) throw new IOException("Truncated TIFF page entries.");
            stream.Position = next;
            if (stream.Read(word, 0, 4) != 4) throw new IOException("Truncated TIFF next-page offset.");
            offset = u32(word, 0);
        }
        if (seen.Count == 0) throw new IOException("TIFF has no pages.");
        return seen.Count;
    }

    private static void Validate(string path)
    {
        var fixedNames = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        using (Package package = Package.Open(path, FileMode.Open, FileAccess.Read))
        foreach (PackagePart part in package.GetParts())
            if (part.ContentType.StartsWith("application/vnd.ms-package.xps-", StringComparison.OrdinalIgnoreCase) && part.ContentType.EndsWith("+xml", StringComparison.OrdinalIgnoreCase))
                fixedNames.Add(Uri.UnescapeDataString(part.Uri.OriginalString).TrimStart('/'));
        using (var file = File.OpenRead(path))
        using (var archive = new ZipArchive(file, ZipArchiveMode.Read))
        {
            long total = 0; var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            if (archive.Entries.Count > 20000) throw new IOException("Too many XPS parts.");
            foreach (var part in archive.Entries)
            {
                string name = part.FullName; total += part.Length;
                if (!names.Add(name) || name.IndexOf('\\') >= 0 || name.StartsWith("/") || name.IndexOf(':') >= 0 ||
                    Array.IndexOf(name.Split('/'), "..") >= 0 || part.Length > MaxInput || total > MaxTotal) throw new IOException("Invalid XPS package.");
                bool fixedPart = fixedNames.Contains(name) || Regex.IsMatch(name, @"\.(fpage|fdoc|fdseq|dict)$", RegexOptions.IgnoreCase);
                if (!fixedPart && !name.EndsWith(".rels", StringComparison.OrdinalIgnoreCase)) continue;
                if (part.Length > 16 * 1024 * 1024) throw new IOException("XPS XML exceeds 16 MB.");
                using (Stream bytes = part.Open())
                using (XmlReader xml = XmlReader.Create(bytes, new XmlReaderSettings { DtdProcessing = DtdProcessing.Prohibit, XmlResolver = null, MaxCharactersInDocument = 16 * 1024 * 1024 }))
                {
                    int nodes = 0;
                    while (xml.Read())
                    {
                        if (++nodes > 500000 || xml.Depth > 128) throw new IOException("XPS XML is too complex.");
                        if (xml.NodeType != XmlNodeType.Element) continue;
                        if (fixedPart && !((xml.NamespaceURI == XpsNamespace && Nodes.Contains(xml.LocalName)) ||
                            (xml.NamespaceURI == XpsNamespace + "/documentstructure" && StructureNodes.Contains(xml.LocalName))))
                            throw new IOException("Unsupported XPS fixed markup: " + xml.LocalName);
                        if (!fixedPart && xml.LocalName == "Relationship" && xml.GetAttribute("TargetMode") == "External") throw new IOException("External XPS relationships are not loaded.");
                        if (xml.MoveToFirstAttribute()) do
                        {
                            string value = Uri.UnescapeDataString(xml.Value).Trim();
                            if (fixedPart && value.StartsWith("{") && !Regex.IsMatch(value, @"^\{StaticResource [^{}]+\}$|^\{ColorConvertedBitmap [^{}]+\}$"))
                                throw new IOException("Unsupported XPS markup extension.");
                            if (xml.LocalName == "Source" || xml.LocalName == "ImageSource" || xml.LocalName == "FontUri" || xml.LocalName == "ColorContext")
                            {
                                if (Regex.IsMatch(value, @"[a-zA-Z][a-zA-Z0-9+.-]*:|\\|^//")) throw new IOException("External XPS resources are not loaded.");
                            }
                            if (fixedPart && xml.NamespaceURI.Length != 0 && xml.NamespaceURI != "http://www.w3.org/XML/1998/namespace" &&
                                xml.NamespaceURI != "http://schemas.microsoft.com/winfx/2006/xaml" && xml.NamespaceURI != "http://www.w3.org/2000/xmlns/")
                                throw new IOException("Unsupported XPS attribute namespace.");
                            if (fixedPart && xml.NamespaceURI == "http://schemas.microsoft.com/winfx/2006/xaml" && xml.LocalName != "Key" && xml.LocalName != "Name")
                                throw new IOException("Unsupported XPS markup directive.");
                        } while (xml.MoveToNextAttribute());
                        xml.MoveToElement();
                    }
                }
            }
        }
    }
}
