// Copyright (c) 2026 MyHomeLib contributors. MIT license; see ../../LICENSE.
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Drawing.Text;
using System.Globalization;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using System.Xml;
using System.Xml.Linq;

// Render an isolated, supported Word drawing. Callers keep the original
// markup and its existing text/table fallback if any part is unsupported.
internal sealed class DrawingMlFigures
{
    private static readonly XNamespace A = "http://schemas.openxmlformats.org/drawingml/2006/main";
    private static readonly XNamespace W = "http://schemas.openxmlformats.org/wordprocessingml/2006/main";
    private static readonly XNamespace G = "http://schemas.microsoft.com/office/word/2010/wordprocessingGroup";
    private static readonly XNamespace S = "http://schemas.microsoft.com/office/word/2010/wordprocessingShape";
    private static readonly XNamespace P = "http://schemas.openxmlformats.org/drawingml/2006/picture";
    private static readonly XNamespace R = "http://schemas.openxmlformats.org/officeDocument/2006/relationships";
    private static readonly XNamespace WP = "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing";
    private static readonly XNamespace WP14 = "http://schemas.microsoft.com/office/word/2010/wordprocessingDrawing";
    private static readonly XNamespace C = "http://schemas.microsoft.com/office/word/2010/wordprocessingCanvas";
    private static readonly XNamespace MC = "http://schemas.openxmlformats.org/markup-compatibility/2006";
    private static readonly XNamespace V = "urn:schemas-microsoft-com:vml";
    private static readonly XNamespace O = "urn:schemas-microsoft-com:office:office";
    private static readonly XNamespace W10 = "urn:schemas-microsoft-com:office:word";
    private const float EmuPerPoint = 12700;
    private const int MaxXmlBytes = 4 * 1024 * 1024;
    private readonly XElement theme, styles, colors, numbering;
    private readonly XElement figure;
    private int objects, characters;

    private sealed class UnsupportedDrawing : Exception { }

    private static void Require(bool condition)
    {
        if (!condition) throw new UnsupportedDrawing();
    }

    private DrawingMlFigures(XElement request, XElement figure)
    {
        theme = request.Element(A + "theme");
        styles = request.Element(W + "styles");
        colors = request.Element(W + "clrSchemeMapping");
        numbering = request.Element(W + "numbering");
        this.figure = figure;
    }

    internal static byte[] Render(string input)
    {
        var request=ReadRequest(input,MaxXmlBytes);
        return request!=null && request.Name=="figure" ? RenderFigure(request,request) : null;
    }

    internal static int RenderBatch(string input, string output)
    {
        var request=ReadRequest(input,4*MaxXmlBytes);
        if (request==null || request.Name!="figures") return 3;
        var framedBody=request.Element(W+"body");
        if (framedBody!=null) return RenderFramedPages(request,framedBody,output);
        var figures=request.Elements("figure").Take(129).ToArray();
        if (figures.Length==0 || figures.Length>128) return 3;
        using (var file=new FileStream(output,FileMode.CreateNew,FileAccess.Write,FileShare.None))
        using (var pictures=new ZipArchive(file,ZipArchiveMode.Create))
        {
            long total=0;
            for (int index=0;index<figures.Length;index++)
            {
                var image=RenderFigure(figures[index],request);
                if (image==null || image.Length>16*1024*1024) continue;
                total+=image.Length;
                if (total>64*1024*1024) break;
                var entry=pictures.CreateEntry(index.ToString(CultureInfo.InvariantCulture)+".png",CompressionLevel.NoCompression);
                using (var stream=entry.Open()) stream.Write(image,0,image.Length);
            }
        }
        return 0;
    }

    private static int RenderFramedPages(XElement request, XElement body, string output)
    {
        var blocks=body.Elements().Take(257).ToArray();
        if (blocks.Length<2 || blocks.Length>256 || blocks.Length%2!=0) return 3;
        var rendered=new List<byte[]>();
        long bytes=0;
        try
        {
            for (int index=0;index<blocks.Length;index+=2)
            {
                var anchor=blocks[index];
                var boundary=blocks[index+1];
                var last=index+2==blocks.Length;
                var boundaryProperties=boundary.Element(W+"pPr");
                var section=last ? boundary : boundaryProperties==null ? null : boundaryProperties.Element(W+"sectPr");
                Require(anchor.Name==W+"p" && section!=null && section.Name==W+"sectPr");
                Require(last || boundary.Name==W+"p" && boundary.Elements().Count()==1 &&
                    boundaryProperties.Elements().All(n=>n==section || n.Name==W+"rPr" || n.Name==W+"spacing"));
                Require(boundary.DescendantNodes().OfType<XText>().All(n=>String.IsNullOrWhiteSpace(n.Value)));
                Require(section.Elements().All(n=>n.Name==W+"pgSz" || n.Name==W+"pgMar" || n.Name==W+"type"));
                var kind=WordValue(section.Element(W+"type"),"nextPage");
                Require(kind=="nextPage" || index==0 && kind=="continuous");
                var properties=anchor.Element(W+"pPr");
                Require(properties==null || properties.Elements().All(n=>n.Name==W+"rPr"));
                var runs=anchor.Elements().Where(n=>n!=properties).ToArray();
                Require(runs.Length>=1 && runs.Length<=32 && runs.All(n=>n.Name==W+"r" &&
                    n.Elements(W+"pict").Count()==1 && n.Elements().All(c=>c.Name==W+"rPr" || c.Name==W+"pict") &&
                    !n.Descendants(W+"vanish").Any() && !n.Descendants(W+"webHidden").Any()));
                var pictures=runs.Select(n=>n.Element(W+"pict")).ToArray();
                var size=section.Element(W+"pgSz");
                Require(size!=null);
                int width=PageExtent(size,W+"w"),height=PageExtent(size,W+"h");
                var position=new Rectangle(0,0,width,height);
                var frame=VmlFrame(new Dictionary<string,string>(),position);
                frame.Add(new XElement(A+"chOff",new XAttribute("x",0),new XAttribute("y",0)),
                    new XElement(A+"chExt",new XAttribute("cx",width),new XAttribute("cy",height)));
                var group=new XElement(G+"wgp",new XElement(G+"grpSpPr",frame));
                var caption=new System.Text.StringBuilder();
                var layers=new List<Tuple<int,XElement>>();
                foreach (var picture in pictures)
                {
                    var source=picture.Element(V+"shape");
                    Require(source!=null);
                    var style=VmlStyle(source);
                    Require(VmlValue(style,"position")=="absolute" &&
                        VmlValue(style,"mso-position-horizontal-relative")=="page" &&
                        VmlValue(style,"mso-position-vertical-relative")=="page" &&
                        style.Keys.All(key=>VmlPositioning.Contains(key) ||
                            new[]{"position","margin-left","margin-top","width","height","z-index"}.Contains(key)));
                    var textbox=source.Element(V+"textbox");
                    var text=textbox==null ? null : textbox.Element(W+"txbxContent");
                    Require(text!=null && text.Elements().All(n=>n.Name==W+"p" &&
                        n.Elements().All(r=>r.Name==W+"pPr" || r.Name==W+"r" &&
                            r.Elements().All(t=>t.Name==W+"rPr" || t.Name==W+"t" || t.Name==W+"tab" ||
                                t.Name==W+"br" || t.Name==W+"cr"))));
                    foreach (var paragraph in text.Elements())
                        caption.AppendLine(String.Concat(paragraph.Descendants(W+"t").Select(n=>n.Value)));
                    var shape=ReadVmlTextBox(picture);
                    var transform=shape.Element(S+"spPr").Element(A+"xfrm");
                    var extent=transform.Element(A+"ext");
                    int left=VmlCoordinate(VmlValue(style,"margin-left","0pt"),true);
                    int top=VmlCoordinate(VmlValue(style,"margin-top","0pt"),true);
                    Require(left>=0 && top>=0 && left+Number(extent,"cx")<=width && top+Number(extent,"cy")<=height);
                    transform.Element(A+"off").SetAttributeValue("x",left);
                    transform.Element(A+"off").SetAttributeValue("y",top);
                    layers.Add(Tuple.Create(VmlCoordinate(VmlValue(style,"z-index","0")),shape));
                }
                Require(caption.Length<=4096 && !String.IsNullOrWhiteSpace(caption.ToString()));
                group.Add(layers.OrderBy(item=>item.Item1).Select(item=>item.Item2));
                var image=new DrawingMlFigures(request,anchor).RenderScene(group,true,true);
                bytes+=image.Length;
                Require(image.Length<=16*1024*1024 && bytes<=64*1024*1024);
                rendered.Add(image);
            }
        }
        catch (UnsupportedDrawing) { return 3; }
        catch (ArgumentException) { return 3; }
        catch (ExternalException) { return 3; }
        catch (FormatException) { return 3; }

        using (var file=new FileStream(output,FileMode.CreateNew,FileAccess.Write,FileShare.None))
        using (var archive=new ZipArchive(file,ZipArchiveMode.Create))
            for (int index=0;index<rendered.Count;index++)
                using (var stream=archive.CreateEntry(index.ToString(CultureInfo.InvariantCulture)+".png",CompressionLevel.NoCompression).Open())
                    stream.Write(rendered[index],0,rendered[index].Length);
        return 0;
    }

    private static int PageExtent(XElement size, XName axis)
    {
        float twips=Number(size,axis);
        Require(twips>=2000 && twips<=36000 && twips==(int)twips);
        return (int)twips*635;
    }

    private static XElement ReadRequest(string input, int limit)
    {
        using (var stream=File.OpenRead(input))
        {
            if (stream.Length>limit) return null;
            using (var reader=XmlReader.Create(stream,new XmlReaderSettings {
                DtdProcessing= DtdProcessing.Prohibit, XmlResolver=null, MaxCharactersInDocument=limit }))
                return XDocument.Load(reader).Root;
        }
    }

    private static byte[] RenderFigure(XElement figure, XElement common)
    {
        try
        {
            var legend=figure.Element("legend");
            if (legend!=null)
                return new DrawingMlFigures(common,figure).RenderLegendMarker(legend);
            var floating=figure.Element("floating");
            if (floating!=null)
                return new DrawingMlFigures(common,figure).RenderFloatingScene(floating);
            var canvas=figure.Element(C+"wpc");
            if (canvas!=null)
                return new DrawingMlFigures(common,figure).RenderCanvas(canvas,figure.Element(WP+"extent"),figure.Element(WP+"effectExtent"));
            var legacy=figure.Element(V+"group");
            var group=legacy==null ? figure.Element(G+"wgp") : ReadVmlGroup(legacy,true,0);
            var legacyBox=figure.Element(W+"pict");
            var inlineOval=figure.Element(V+"oval");
            var shape=inlineOval!=null ? ReadVmlInlineOval(inlineOval) :
                legacyBox==null ? figure.Element(S+"wsp") : ReadVmlTextBox(legacyBox);
            Require((group==null)!=(shape==null));
            return new DrawingMlFigures(common,figure).RenderScene(group??shape,group!=null);
        }
        catch (UnsupportedDrawing) { return null; }
        catch (ArgumentException) { return null; }
        catch (ExternalException) { return null; }
        catch (FormatException) { return null; }
    }

    private static readonly string[] VmlPositioning = {
        "mso-position-horizontal","mso-position-vertical",
        "mso-position-horizontal-relative","mso-position-vertical-relative"
    };
    private static readonly string[] VmlWrapping = {
        "mso-wrap-distance-left","mso-wrap-distance-right","mso-wrap-distance-top","mso-wrap-distance-bottom"
    };

    private static IDictionary<string,string> VmlStyle(XElement node,bool ignorePageOrder=false)
    {
        var result=new Dictionary<string,string>(StringComparer.OrdinalIgnoreCase);
        foreach (var token in ((string)node.Attribute("style")??"").Split(';'))
        {
            if (String.IsNullOrWhiteSpace(token)) continue;
            var fields=token.Split(':');
            Require(fields.Length==2);
            var key=fields[0].Trim();
            var value=fields[1].Trim();
            if (key=="flip")
            {
                Require(value=="x" || value=="y");
                key+=value;
            }
            // The outer layer belongs to the page. Only the ordering of
            // children matters when rendering the group on its own.
            if (ignorePageOrder && key.Equals("z-index",StringComparison.OrdinalIgnoreCase))
            {
                VmlCoordinate(value);
                continue;
            }
            Require(!result.ContainsKey(key));
            result.Add(key,value);
        }
        Require(!result.ContainsKey("position") || result["position"]=="absolute" || result["position"]=="relative");
        return result;
    }

    private static int VmlCoordinate(string value,bool points=false)
    {
        decimal coordinate;
        Require(value!=null && value.Length<=30 && (!points || value.EndsWith("pt",StringComparison.Ordinal)));
        Require(Decimal.TryParse(points ? value.Substring(0,value.Length-2) : value,
            NumberStyles.AllowLeadingSign | NumberStyles.AllowDecimalPoint,CultureInfo.InvariantCulture,out coordinate));
        if (points) coordinate*=12700;
        Require(Math.Abs(coordinate)<=100000000);
        return (int)Math.Round(coordinate);
    }

    private static Point VmlPair(string value, bool allowZeroY=false)
    {
        var fields=(value??"").Split(new[]{',',' ','\t'},StringSplitOptions.RemoveEmptyEntries);
        if (allowZeroY && fields.Length==1 && !value.Contains(",")) return new Point(VmlCoordinate(fields[0]),0);
        Require(fields.Length==2);
        return new Point(VmlCoordinate(fields[0]),VmlCoordinate(fields[1]));
    }

    private static string VmlValue(IDictionary<string,string> style,string key,string fallback=null)
    {
        string value;
        return style.TryGetValue(key,out value) ? value : fallback;
    }

    private static XElement VmlFrame(IDictionary<string,string> style,Rectangle bounds)
    {
        Require(bounds.Width>=0 && bounds.Height>=0);
        var element=new XElement(A+"xfrm",
            new XElement(A+"off",new XAttribute("x",bounds.Left),new XAttribute("y",bounds.Top)),
            new XElement(A+"ext",new XAttribute("cx",bounds.Width),new XAttribute("cy",bounds.Height)));
        var rotation=VmlValue(style,"rotation");
        if (rotation!=null)
        {
            double degrees;
            var fixedDegrees=rotation.EndsWith("fd",StringComparison.Ordinal);
            Require(Double.TryParse(fixedDegrees ? rotation.Substring(0,rotation.Length-2) : rotation,
                fixedDegrees ? NumberStyles.AllowLeadingSign : NumberStyles.Float,CultureInfo.InvariantCulture,out degrees));
            Require(fixedDegrees ? degrees>=Int32.MinValue && degrees<=Int32.MaxValue : Math.Abs(degrees)<=360);
            if (fixedDegrees) degrees/=65536;
            degrees%=360;
            element.SetAttributeValue("rot",Math.Round(degrees*60000));
        }
        if (style.ContainsKey("flipx")) element.SetAttributeValue("flipH","1");
        if (style.ContainsKey("flipy")) element.SetAttributeValue("flipV","1");
        return element;
    }

    private static XElement ReadVmlGroup(XElement node,bool root,int depth)
    {
        Require(depth<16 && node.Attributes().All(a=>a.IsNamespaceDeclaration ||
            new[]{"id","style","coordorigin","coordsize"}.Contains(a.Name.ToString()) || a.Name==O+"allowincell"));
        var style=VmlStyle(node,root);
        Require(style.Keys.All(name=>VmlPositioning.Contains(name) ||
            root && (name=="text-align" || VmlWrapping.Contains(name)) ||
            new[]{"position","left","top","margin-left","margin-top","width","height","z-index","rotation","flipx","flipy"}.Contains(name)));
        var origin=VmlPair((string)node.Attribute("coordorigin")??"0,0",true);
        var size=VmlPair((string)node.Attribute("coordsize"));
        Require(size.X>0 && size.Y>0);
        var bounds=new Rectangle(root ? 0 : VmlCoordinate(VmlValue(style,"left","0")),
            root ? 0 : VmlCoordinate(VmlValue(style,"top","0")),
            VmlCoordinate(VmlValue(style,"width"),root),VmlCoordinate(VmlValue(style,"height"),root));
        var frame=VmlFrame(style,bounds);
        frame.Add(new XElement(A+"chOff",new XAttribute("x",origin.X),new XAttribute("y",origin.Y)),
            new XElement(A+"chExt",new XAttribute("cx",size.X),new XAttribute("cy",size.Y)));
        var group=new XElement(root ? G+"wgp" : G+"grpSp",new XElement(G+"grpSpPr",frame));
        // The wrapping marker positions the entire group among page paragraphs.
        var layers=node.Elements().Where(e=>e.Name!=V+"shapetype" && !(root && e.Name==W10+"wrap"))
            .Select(e=>new { Node=e, Layer=VmlCoordinate(VmlValue(VmlStyle(e),"z-index","0")) });
        foreach (var shape in layers.OrderBy(e=>e.Layer))
            group.Add(shape.Node.Name==V+"group" ? ReadVmlGroup(shape.Node,false,depth+1) : ReadVmlShape(shape.Node));
        return group;
    }

    private static XElement ReadVmlFreeform(XElement shape)
    {
        var coordinates=VmlPair((string)shape.Attribute("coordsize"));
        var data=((string)shape.Attribute("path")??"").Trim();
        Require(coordinates.X>0 && coordinates.Y>0 && data.Length<=32000);
        var path=new XElement(A+"path",new XAttribute("w",coordinates.X),new XAttribute("h",coordinates.Y));
        var current=Point.Empty;
        var start=Point.Empty;
        var started=false;
        var ended=false;
        var offset=0;
        var segments=0;
        foreach (Match token in Regex.Matches(data,@"\G(h[a-i]|[mlrctvxe])([-0-9,\s]*)"))
        {
            Require(!ended && segments<=4096);
            offset=token.Index+token.Length;
            var op=token.Groups[1].Value[0];
            var args=token.Groups[2].Value.Trim();
            if (op=='h')
            {
                // These commands describe vertex editing behavior only.
                Require(started && args.Length==0);
                continue;
            }
            if (op=='e')
            {
                Require(args.Length==0);
                ended=true;
                continue;
            }
            if (op=='x')
            {
                Require(started && args.Length==0);
                path.Add(new XElement(A+"close"));
                started=false;
                current=start;
                continue;
            }
            var move=op=='m' || op=='t';
            var line=op=='l' || op=='r';
            var relative=op=='t' || op=='r' || op=='v';
            Require(args.Length>0 && (move || started));
            // An omitted comma-delimited coordinate has the value zero.
            var values=Regex.Split(Regex.Replace(args,@"\s*,\s*",","),@",|\s+")
                .Select(value=>value.Length==0 ? 0 : VmlCoordinate(value)).ToArray();
            var count=move || line ? 2 : 6;
            Require(values.Length>=count && values.Length%count==0 && (!move || values.Length==2));
            for (var i=0;i<values.Length;i+=count)
            {
                Require(++segments<=4096);
                var points=new Point[count/2];
                for (var p=0;p<points.Length;p++)
                {
                    var x=values[i+2*p]+(relative ? current.X : 0);
                    var y=values[i+2*p+1]+(relative ? current.Y : 0);
                    Require(Math.Abs(x)<=100000000 && Math.Abs(y)<=100000000);
                    points[p]=new Point(x,y);
                }
                current=points[points.Length-1];
                if (move) { start=current; started=true; }
                path.Add(PathCommand(move ? "moveTo" : line ? "lnTo" : "cubicBezTo",points));
            }
        }
        Require(ended && offset==data.Length && path.Elements().Any(e=>e.Name==A+"lnTo" || e.Name==A+"cubicBezTo"));
        return new XElement(A+"custGeom",new XElement(A+"pathLst",path));
    }

    private static XElement PathCommand(string name,params Point[] points)
    {
        return new XElement(A+name,points.Select(p=>new XElement(A+"pt",
            new XAttribute("x",p.X),new XAttribute("y",p.Y))));
    }

    private static XElement ReadVmlArc(XElement shape)
    {
        var size=VmlPair((string)shape.Attribute("coordsize"));
        var data=(string)shape.Attribute("path")??"";
        Require(size.X>0 && size.Y>0 && data.Length<=300);
        var path=Regex.Match(data,@"^wr(?<arc>-?[0-9]+(?:,-?[0-9]+){7})nfewr\k<arc>l(?<center>-?[0-9]+,-?[0-9]+)nsxe$");
        Require(path.Success);
        var points=path.Groups["arc"].Value.Split(',').Select(v=>VmlCoordinate(v)).ToArray();
        var center=VmlPair(path.Groups["center"].Value);
        var rx=(points[2]-points[0])/2.0;
        var ry=(points[3]-points[1])/2.0;
        Require(rx>0 && ry>0 && center.X==points[0]+rx && center.Y==points[1]+ry);
        var first=new Point(points[4],points[5]);
        var last=new Point(points[6],points[7]);
        Func<Point,double> angle=p=> {
            var x=(p.X-center.X)/rx;
            var y=(p.Y-center.Y)/ry;
            Require(Math.Abs(x*x+y*y-1)<.001);
            return Math.Atan2(y,x);
        };
        var start=angle(first);
        var sweep=angle(last)-start;
        if (sweep<=0) sweep+=2*Math.PI;
        Require(first!=last);
        var steps=(int)Math.Ceiling(sweep/(Math.PI/2));
        var interval=sweep/steps;
        var tangent=4*Math.Tan(interval/4)/3;
        Func<double,double,Point> vertex=(at,offset)=>new Point(
            (int)Math.Round(center.X+rx*(Math.Cos(at)-offset*Math.Sin(at))),
            (int)Math.Round(center.Y+ry*(Math.Sin(at)+offset*Math.Cos(at))));
        var stroke=new XElement(A+"path",new XAttribute("w",size.X),new XAttribute("h",size.Y),PathCommand("moveTo",first));
        for (var i=0;i<steps;i++)
        {
            var a=start+i*interval;
            var b=a+interval;
            stroke.Add(PathCommand("cubicBezTo",vertex(a,tangent),vertex(b,-tangent),i+1==steps ? last : vertex(b,0)));
        }
        var fill=new XElement(stroke);
        fill.SetAttributeValue("stroke","0");
        fill.Add(PathCommand("lnTo",center),new XElement(A+"close"));
        return new XElement(A+"custGeom",new XElement(A+"pathLst",stroke,fill));
    }

    private static bool VmlOn(XElement shape,string attribute,bool fallback)
    {
        var value=(string)shape.Attribute(attribute);
        Require(value==null || new[]{"t","f","true","false","1","0"}.Contains(value));
        return value==null ? fallback : new[]{"t","true","1"}.Contains(value);
    }

    private static XElement VmlFill(string color)
    {
        if (String.Equals(color,"white",StringComparison.OrdinalIgnoreCase)) color="#ffffff";
        if (String.Equals(color,"black",StringComparison.OrdinalIgnoreCase)) color="#000000";
        Require(color!=null && Regex.IsMatch(color,"^#[0-9a-fA-F]{6}$"));
        return new XElement(A+"solidFill",new XElement(A+"srgbClr",new XAttribute("val",color.Substring(1))));
    }

    private static XElement ReadVmlTextBox(XElement picture)
    {
        var children=picture.Elements().ToArray();
        Require(children.Length>=1 && children.Length<=2);
        var shape=children[children.Length-1];
        Require(shape.Name==V+"shape" && (string)shape.Attribute("type")=="#_x0000_t202" &&
            shape.Element(V+"textbox")!=null && shape.Attribute("path")==null);
        if (children.Length==2)
        {
            var preset=children[0];
            Require(preset.Name==V+"shapetype" && (string)preset.Attribute("id")=="_x0000_t202" &&
                (string)preset.Attribute("coordsize")=="21600,21600" &&
                (string)preset.Attribute(O+"spt")=="202" && (string)preset.Attribute("path")=="m,l,21600r21600,l21600,xe" &&
                preset.Attributes().All(a=>a.IsNamespaceDeclaration || a.Name=="id" || a.Name=="coordsize" ||
                    a.Name==O+"spt" || a.Name=="path") &&
                preset.Elements().All(n=>n.Name==V+"stroke" && (string)n.Attribute("joinstyle")=="miter" &&
                    n.Attributes().Count(a=>!a.IsNamespaceDeclaration)==1 && !n.HasElements ||
                    n.Name==V+"path" && n.Attributes().All(a=>a.IsNamespaceDeclaration ||
                    a.Name=="gradientshapeok" || a.Name==O+"extrusionok" ||
                    a.Name==O+"connecttype" && a.Value=="rect") && !n.HasElements));
        }
        return ReadVmlShape(shape,true);
    }

    private static XElement ReadVmlInlineOval(XElement oval)
    {
        var style=VmlStyle(oval);
        Require(VmlValue(style,"position","relative")=="relative" &&
            VmlValue(style,"mso-position-horizontal-relative")=="char" &&
            VmlValue(style,"mso-position-vertical-relative")=="line" &&
            style.Keys.All(key=>key=="width" || key=="height" || key=="position" ||
                key=="mso-position-horizontal-relative" || key=="mso-position-vertical-relative") &&
            VmlCoordinate(VmlValue(style,"width"),true)<=64*EmuPerPoint &&
            VmlCoordinate(VmlValue(style,"height"),true)<=64*EmuPerPoint);
        var shape=new XElement(oval);
        foreach (var child in shape.Elements().ToArray())
        {
            if (child.Name==V+"textbox")
            {
                var content=child.Element(W+"txbxContent");
                Require(child.Elements().Count()==1 && content!=null &&
                    !content.Attributes().Any(a=>!a.IsNamespaceDeclaration) &&
                    !child.Attributes().Any(a=>!a.IsNamespaceDeclaration) &&
                    String.IsNullOrWhiteSpace(child.Value) && content.Elements().All(p=>p.Name==W+"p" &&
                    p.Elements().All(property=>property.Name==W+"pPr" &&
                        property.Elements().All(indent=>indent.Name==W+"ind" && !indent.HasElements))));
            }
            else if (child.Name==W10+"wrap")
                Require((string)child.Attribute("type")=="none" && !child.HasElements &&
                    child.Attributes().Count(a=>!a.IsNamespaceDeclaration)==1);
            else
                Require(child.Name==W10+"anchorlock" && !child.HasElements &&
                    !child.Attributes().Any(a=>!a.IsNamespaceDeclaration));
            child.Remove();
        }
        return ReadVmlShape(shape,true);
    }

    private static XElement ReadVmlShape(XElement node,bool standalone=false)
    {
        var type=(string)node.Attribute("type");
        var isArc=node.Name==V+"shape" && type=="#_x0000_t19";
        var isConnector=node.Name==V+"shape" && type=="#_x0000_t32" &&
            (string)node.Attribute(O+"connectortype")=="straight" &&
            !new[]{"path","coordsize","from","to"}.Any(name=>node.Attribute(name)!=null);
        Require(node.Attributes().All(a=>a.IsNamespaceDeclaration || new[]{"id","type","style","filled","stroked",
            "from","to","strokeweight","strokecolor","fillcolor","path","coordsize"}.Contains(a.Name.ToString()) ||
            a.Name=="wrapcoords" || a.Name==O+"allowincell" || isArc && a.Name=="adj" || isConnector && a.Name==O+"connectortype"));
        var style=VmlStyle(node);
        Require(style.Keys.All(name=>VmlPositioning.Contains(name) ||
            standalone && (name=="margin-left" || name=="margin-top" || name=="text-align" || VmlWrapping.Contains(name)) ||
            !standalone && (name=="mso-width-relative" || name=="mso-height-relative") ||
            new[]{"position","left","top","width","height","z-index","rotation","flipx","flipy","mso-wrap-edited"}.Contains(name)));
        if (!standalone && node.Name==V+"shape" && type=="#_x0000_t75")
            return ReadVmlPicture(node,style);
        var isLine=node.Name==V+"line" && type=="#_x0000_t20";
        var isFreeform=node.Name==V+"shape" && type==null && node.Attribute("path")!=null;
        var isRect=node.Name==V+"rect" && type=="#_x0000_t1" || node.Name==V+"shape" && type=="#_x0000_t202";
        var isOval=node.Name==V+"oval" && (type==null || type=="#_x0000_t3");
        Require(isLine || isConnector || isFreeform || isRect || isOval || isArc);
        Require(node.Elements().All(n=>n.Name==V+"textbox" || n.Name==V+"stroke" ||
            (standalone ? n.Name==W10+"wrap" : IsTopAndBottomWrap(n)) ||
            isFreeform && n.Name==V+"path" && !n.HasElements &&
            n.Attributes().All(a=>a.IsNamespaceDeclaration || a.Name=="arrowok")));
        Rectangle bounds;
        if (isLine)
        {
            var from=VmlPair((string)node.Attribute("from"));
            var to=VmlPair((string)node.Attribute("to"));
            Require(to.X>=from.X && to.Y>=from.Y && to!=from);
            bounds=Rectangle.FromLTRB(from.X,from.Y,to.X,to.Y);
        }
        else bounds=new Rectangle(standalone ? 0 : VmlCoordinate(VmlValue(style,"left","0")),
            standalone ? 0 : VmlCoordinate(VmlValue(style,"top","0")),
            VmlCoordinate(VmlValue(style,"width"),standalone),VmlCoordinate(VmlValue(style,"height"),standalone));
        var geometry=isArc ? ReadVmlArc(node) : isFreeform ? ReadVmlFreeform(node) : new XElement(A+"prstGeom",
            new XAttribute("prst",isLine || isConnector ? "line" : isOval ? "ellipse" : "rect"));
        var filled=VmlOn(node,"filled",!isLine && !isConnector && (!isFreeform || geometry.Descendants(A+"close").Any()));
        Require(!filled || !isLine && !isConnector);
        var fill=filled ? VmlFill((string)node.Attribute("fillcolor")??"#ffffff") : new XElement(A+"noFill");
        var weight=(string)node.Attribute("strokeweight");
        var thickness=weight==null ? 9525 : VmlCoordinate(weight,weight.EndsWith("pt",StringComparison.Ordinal));
        Require(thickness>=0);
        var line=new XElement(A+"ln",new XAttribute("w",thickness));
        line.Add(VmlOn(node,"stroked",true) && thickness>0 ?
            VmlFill((string)node.Attribute("strokecolor")??"#000000") : new XElement(A+"noFill"));
        var stroke=node.Element(V+"stroke");
        if (stroke!=null)
        {
            Require(stroke.Attributes().All(a=>a.IsNamespaceDeclaration ||
                new[]{"startarrow","startarrowwidth","startarrowlength","endarrow","endarrowwidth","endarrowlength"}
                    .Contains(a.Name.ToString())) && !stroke.HasElements);
            foreach (var end in new[]{"startarrow","endarrow"})
            {
                var tip=(string)stroke.Attribute(end)??"none";
                if (tip=="none") continue;
                Require(tip=="classic" && (isLine || isConnector || isFreeform));
                var tail=new XElement(A+(end=="startarrow" ? "headEnd" : "tailEnd"),new XAttribute("type","stealth"));
                var width=(string)stroke.Attribute(end+"width")??"medium";
                var length=(string)stroke.Attribute(end+"length")??"medium";
                Require(width=="narrow" || width=="medium");
                Require(length=="medium");
                tail.SetAttributeValue("w",width=="narrow" ? "sm" : "med");
                line.Add(tail);
            }
        }
        var shape=new XElement(S+"wsp",new XElement(S+"spPr",VmlFrame(style,bounds),geometry,fill,line));
        var box=node.Element(V+"textbox");
        if (box!=null)
        {
            Require(box.Attributes().All(a=>a.IsNamespaceDeclaration || a.Name=="inset") &&
                box.Elements().Count()==1 && box.Element(W+"txbxContent")!=null);
            var body=new XElement(S+"bodyPr");
            var inset=(string)box.Attribute("inset");
            if (inset!=null)
            {
                var margins=inset.Split(',');
                var sides=new[]{"lIns","tIns","rIns","bIns"};
                Require(margins.Length==sides.Length);
                for (int i=0;i<sides.Length;i++)
                {
                    var value=margins[i].Trim();
                    var margin=value=="0" ? 0 : VmlCoordinate(value,true);
                    Require(margin>=0);
                    body.SetAttributeValue(sides[i],margin);
                }
            }
            shape.Add(new XElement(S+"txbx",new XElement(box.Element(W+"txbxContent"))),body);
        }
        return shape;
    }

    private static XElement ReadVmlPicture(XElement node,IDictionary<string,string> style,bool inline=false)
    {
        var image=node.Element(V+"imagedata");
        Require(image!=null && node.Elements().All(child=>child==image || !inline && IsTopAndBottomWrap(child)) &&
            !image.HasElements &&
            image.Attributes().All(a=>a.IsNamespaceDeclaration || a.Name==R+"id" || a.Name==O+"title" || a.Name=="grayscale") &&
            node.Attribute("path")==null && !VmlOn(node,"filled",false) && !VmlOn(node,"stroked",false));
        var id=(string)image.Attribute(R+"id");
        Require(!String.IsNullOrEmpty(id));
        var bounds=new Rectangle(inline ? 0 : VmlCoordinate(VmlValue(style,"left","0")),
            inline ? 0 : VmlCoordinate(VmlValue(style,"top","0")),VmlCoordinate(VmlValue(style,"width"),inline),
            VmlCoordinate(VmlValue(style,"height"),inline));
        var blip=new XElement(A+"blip",new XAttribute(R+"embed",id));
        if (VmlOn(image,"grayscale",false)) blip.Add(new XElement(A+"grayscl"));
        return new XElement(P+"pic",new XElement(P+"blipFill",blip,
            new XElement(A+"stretch",new XElement(A+"fillRect"))),new XElement(P+"spPr",VmlFrame(style,bounds),
            new XElement(A+"prstGeom",new XAttribute("prst","rect"))));
    }

    private static bool IsTopAndBottomWrap(XElement node)
    {
        return node.Name==W10+"wrap" && !node.HasElements && String.IsNullOrWhiteSpace(node.Value) &&
            (string)node.Attribute("type")=="topAndBottom" &&
            node.Attributes().All(a=>a.IsNamespaceDeclaration || a.Name=="type");
    }

    private static int Number(XElement element, XName key, int defaultValue = 0)
    {
        if (element == null || element.Attribute(key) == null) return defaultValue;
        int value;
        Require(Int32.TryParse((string)element.Attribute(key), NumberStyles.Integer,
            CultureInfo.InvariantCulture, out value) && Math.Abs((long)value) <= 1000000000);
        return value;
    }

    private static bool On(XElement element, XName key)
    {
        var value = (string)element.Attribute(key);
        Require(value == null || value == "0" || value == "1" || value == "false" || value == "true");
        return value == "1" || value == "true";
    }

    private static Matrix Frame(XElement transform, bool group, out float width, out float height, bool rotate=true)
    {
        Require(transform != null && transform.Element(A + "off") != null && transform.Element(A + "ext") != null);
        var offset = transform.Element(A + "off");
        var extent = transform.Element(A + "ext");
        width = Number(extent, "cx"); height = Number(extent, "cy");
        Require(width >= 0 && height >= 0);
        var x = Number(offset, "x") + width/2;
        var y = Number(offset, "y") + height/2;
        float cx = width, cy = height, ox = 0, oy = 0, sx = 1, sy = 1;
        if (group)
        {
            var childOffset = transform.Element(A + "chOff");
            var childExtent = transform.Element(A + "chExt");
            Require(childOffset != null && childExtent != null);
            cx = Number(childExtent, "cx"); cy = Number(childExtent, "cy");
            Require(cx > 0 && cy > 0 && width > 0 && height > 0);
            ox = Number(childOffset, "x"); oy = Number(childOffset, "y");
            sx = width/cx; sy = height/cy;
        }
        if (On(transform, "flipH")) sx = -sx;
        if (On(transform, "flipV")) sy = -sy;
        var frame = new Matrix();
        frame.Translate(x, y);
        if (rotate) frame.Rotate(Number(transform, "rot")/60000f);
        frame.Scale(sx, sy);
        frame.Translate(-ox-cx/2, -oy-cy/2);
        return frame;
    }

    private byte[] RenderScene(XElement scene,bool group,bool fullPage=false)
    {
        var properties=scene.Element(group ? G+"grpSpPr" : S+"spPr");
        Require(properties!=null);
        var transform = properties.Element(A + "xfrm");
        Require(transform != null);
        var rotation=group ? 0 : Number(transform,"rot");
        const int quarter=90*60000;
        Require(rotation%quarter==0);
        var turns=(rotation/quarter%4+4)%4;
        var extent = transform.Element(A + "ext");
        var width = Number(extent,"cx")/EmuPerPoint;
        var height = Number(extent,"cy")/EmuPerPoint;
        var line=!group && IsStraightLine(properties.Element(A+"prstGeom"));
        Require(width <= 4000 && height <= 4000 && (line ? width>=0 && height>=0 && Math.Max(width,height)>1 : width>1 && height>1));
        var body=group ? null : scene.Element(S+"bodyPr");
        if (body!=null && body.Element(A+"spAutoFit")!=null)
        {
            Require(turns==0 && !On(transform,"flipH") && !On(transform,"flipV"));
            return RenderAutoFitTextBox(scene,properties,body,width,height);
        }
        var offset = transform.Element(A + "off");
        var legacyBox=figure.Element(W+"pict")!=null;
        var inlineOval=figure.Element(V+"oval")!=null;
        var scale = Math.Min(legacyBox || inlineOval ? 96f/72 : 4f, 2024f/Math.Max(width,height));
        var legacy=figure.Element(V+"group")!=null;
        var inset=fullPage ? 0 : legacy ? 96 : group ? 12 : 24;
        var contentWidth=(int)Math.Ceiling(scale*width);
        var contentHeight=(int)Math.Ceiling(scale*height);
        using (var bitmap = new Bitmap(contentWidth+2*inset,contentHeight+2*inset,PixelFormat.Format32bppArgb))
        {
            using (var surface = Graphics.FromImage(bitmap))
            using (var fromEmu = new Matrix(1/EmuPerPoint,0,0,1/EmuPerPoint,
                -Number(offset,"x")/EmuPerPoint,-Number(offset,"y")/EmuPerPoint))
            {
                // A white page keeps dark lines and labels visible in dark ebook themes.
                surface.Clear(inlineOval ? Color.Transparent : Color.White);
                surface.PageUnit = GraphicsUnit.Pixel;
                surface.SmoothingMode = SmoothingMode.AntiAlias;
                surface.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
                surface.TranslateTransform(inset,inset);
                surface.ScaleTransform(scale,scale);
                if (group) DrawGroup(scene,fromEmu,surface,0);
                else DrawShape(scene,fromEmu,surface,false);
            }
            if (turns!=0) bitmap.RotateFlip((RotateFlipType)turns);
            using (var encoded = new MemoryStream())
            {
                if (inlineOval)
                {
                    var padding=(int)Math.Ceiling(scale*Number(properties.Element(A+"ln"),"w")/(2*EmuPerPoint));
                    Require(padding<=4);
                    var bounds=new Rectangle(inset-padding,inset-padding,contentWidth+2*padding,contentHeight+2*padding);
                    using (var cropped=bitmap.Clone(bounds,PixelFormat.Format32bppArgb))
                        cropped.Save(encoded,ImageFormat.Png);
                }
                else if (legacy || legacyBox && turns==0)
                    using (var cropped=CropVmlCanvas(bitmap,new Rectangle(inset,inset,contentWidth,contentHeight),legacyBox ? 2 : 12))
                        cropped.Save(encoded,ImageFormat.Png);
                else bitmap.Save(encoded, ImageFormat.Png);
                return encoded.ToArray();
            }
        }
    }

    private sealed class FloatingLayer
    {
        public XElement Shape;
        public RectangleF Ink;
        public float Left, Top;
        public uint Order;
    }

    private static float FloatingOffset(XElement anchor, string axis, string origin)
    {
        var position=anchor.Element(WP+axis);
        Require(position!=null && (string)position.Attribute("relativeFrom")==origin &&
            position.Elements().Count()==1 && position.Element(WP+"posOffset")!=null);
        int offset;
        Require(Int32.TryParse(position.Element(WP+"posOffset").Value,NumberStyles.Integer,
            CultureInfo.InvariantCulture,out offset) && Math.Abs((long)offset)<=4000*EmuPerPoint);
        return offset/EmuPerPoint;
    }

    private FloatingLayer ReadFloatingLayer(XElement drawing,float paragraphTop)
    {
        var anchor=drawing.Element(WP+"anchor");
        Require(anchor!=null && drawing.Elements().Count()==1 && !On(anchor,"simplePos") &&
            !On(anchor,"behindDoc") && On(anchor,"allowOverlap"));
        var wrap=anchor.Element(WP+"wrapNone");
        var graphic=anchor.Element(A+"graphic");
        var data=graphic==null ? null : graphic.Element(A+"graphicData");
        var shape=data==null ? null : data.Element(S+"wsp");
        Require(wrap!=null && wrap.Attributes().All(attribute=>attribute.IsNamespaceDeclaration) && !wrap.HasElements && shape!=null &&
            (string)data.Attribute("uri")==S.NamespaceName && data.Elements().Count()==1 &&
            graphic.Elements().Count()==1);
        foreach (var item in anchor.Elements())
        {
            if (item.Name==WP14+"sizeRelH" || item.Name==WP14+"sizeRelV")
            {
                var percent=item.Name==WP14+"sizeRelH" ? "pctWidth" : "pctHeight";
                Require(item.Elements().Count()==1 && (string)item.Element(WP14+percent)=="0");
            }
            else Require(item==wrap || item==graphic || item.Name==WP+"simplePos" ||
                item.Name==WP+"positionH" || item.Name==WP+"positionV" || item.Name==WP+"extent" ||
                item.Name==WP+"effectExtent" || item.Name==WP+"docPr" || item.Name==WP+"cNvGraphicFramePr");
        }
        Require(!shape.Descendants().Any(n=>n.Name==W+"tbl" || n.Name==W+"hyperlink" ||
            n.Name==W+"footnoteReference" || n.Name==W+"endnoteReference"));
        var bounds=anchor.Element(WP+"extent");
        var props=shape.Element(S+"spPr");
        var transform=props==null ? null : props.Element(A+"xfrm");
        var size=transform==null ? null : transform.Element(A+"ext");
        var offset=transform==null ? null : transform.Element(A+"off");
        Require(bounds!=null && size!=null && offset!=null && Number(transform,"rot")==0 &&
            Number(offset,"x")==0 && Number(offset,"y")==0);
        int width=Number(bounds,"cx"),height=Number(bounds,"cy");
        Require(width>=0 && height>=0 && (width>0 || height>0) &&
            width==Number(size,"cx") && height==Number(size,"cy") &&
            ((width>0 && height>0) || IsStraightLine(props.Element(A+"prstGeom"))));
        var x=FloatingOffset(anchor,"positionH","column");
        var y=paragraphTop+FloatingOffset(anchor,"positionV","paragraph");
        var effects=anchor.Element(WP+"effectExtent");
        var outline=props.Element(A+"ln");
        var style=shape.Element(S+"style");
        var inherited=style==null ? null : ThemeStyle(style.Element(A+"lnRef"),"lnStyleLst");
        var stroke=outline==null && inherited==null ? 0 : Number(outline,"w",Number(inherited,"w",9525))/EmuPerPoint;
        Require(stroke>=0 && stroke<=30);
        // Some producers write effectExtent=0 even for a visible outline.
        var margin=stroke/2;
        if (IsStraightLine(props.Element(A+"prstGeom")) &&
            new[]{"headEnd","tailEnd"}.Any(name=>{
                var end=StrokeChild(outline,inherited,name);
                return end!=null && ((string)end.Attribute("type")??"none")!="none";
            })) margin=4*stroke;
        var padding=new[]{"l","r","t","b"}.Select(edge=>Number(effects,edge)/EmuPerPoint).ToArray();
        Require(margin<=36 && padding.All(value=>value>=0 && value<=36));
        var left=Math.Max(margin,padding[0]);
        var right=Math.Max(margin,padding[1]);
        var top=Math.Max(margin,padding[2]);
        var bottom=Math.Max(margin,padding[3]);
        uint order;
        Require(UInt32.TryParse((string)anchor.Attribute("relativeHeight"),NumberStyles.None,
            CultureInfo.InvariantCulture,out order));
        return new FloatingLayer { Shape=shape, Left=x, Top=y, Order=order,
            Ink=RectangleF.FromLTRB(x-left,y-top,x+width/EmuPerPoint+right,y+height/EmuPerPoint+bottom) };
    }

    private static XElement FloatingDrawingChoice(XElement node)
    {
        if (node.Name!=MC+"AlternateContent") return node;
        var branches=node.Elements(MC+"Choice").ToArray();
        Require(branches.Length==1 && branches[0].Elements().Count()==1 &&
            node.Elements().All(child=>child==branches[0] || child.Name==MC+"Fallback"));
        return branches[0].Elements().Single();
    }

    private LabelStyle FloatingParagraphStyle(LabelStyle defaultStyle,LabelStyle normalStyle,XElement properties)
    {
        if (properties==null) return normalStyle;
        // An explicit break, borders, numbering or visible text must stay in
        // the normal document flow rather than being replaced by this diagram.
        Require(properties.Elements().All(n=>n.Name==W+"pStyle" || n.Name==W+"spacing" ||
            n.Name==W+"ind" || n.Name==W+"jc" || n.Name==W+"tabs" || n.Name==W+"rPr"));
        var paragraphStyle=properties.Element(W+"pStyle");
        var style=paragraphStyle==null ? normalStyle : defaultStyle;
        if (paragraphStyle!=null) InheritStyle(ref style,WordValue(paragraphStyle,""),true);
        ParagraphStyle(ref style,properties);
        TextStyle(ref style,properties.Element(W+"rPr"));
        return style;
    }

    private static float FloatingLineHeight(LabelStyle style)
    {
        Require(style.Size>=1 && style.Size<=72 && style.Before>=0 && style.After>=0 &&
            style.LineSpacing>0 && style.LineSpacing<=4800);
        var face=style.FontFlags & (FontStyle.Bold|FontStyle.Italic);
        using (var font=new Font(style.Family,style.Size,face,GraphicsUnit.Point))
        {
            var height=font.Size*font.FontFamily.GetLineSpacing(face)/font.FontFamily.GetEmHeight(face);
            if (style.LineRule=="exact") return style.LineSpacing/20f;
            if (style.LineRule=="atLeast") return Math.Max(height,style.LineSpacing/20f);
            return height*style.LineSpacing/240f;
        }
    }

    private LabelStyle NormalFloatingStyle(LabelStyle defaultStyle)
    {
        var normal=styles==null ? null : styles.Elements(W+"style").FirstOrDefault(n=>
            (string)n.Attribute(W+"type")=="paragraph" && On(n,W+"default"));
        if (normal!=null) InheritStyle(ref defaultStyle,(string)normal.Attribute(W+"styleId"),true);
        return defaultStyle;
    }

    private byte[] RenderLegendMarker(XElement legend)
    {
        var paragraphs=legend.Elements().Take(3).ToArray();
        Require((paragraphs.Length==1 || paragraphs.Length==2) && paragraphs.All(node=>node.Name==W+"p"));
        var defaultStyle=DefaultLabelStyle();
        var normalStyle=NormalFloatingStyle(defaultStyle);
        LabelStyle indentStyle=normalStyle, labelStyle=normalStyle;
        FloatingLayer marker=null;
        int spaces=0;
        float labelTop=0;
        for(int index=0;index<paragraphs.Length;index++)
        {
            var properties=paragraphs[index].Element(W+"pPr");
            var style=FloatingParagraphStyle(defaultStyle,normalStyle,properties);
            if (index==0) indentStyle=style;
            else labelTop=FloatingLineHeight(indentStyle)+Math.Max(indentStyle.After,style.Before);
            foreach(var run in paragraphs[index].Elements().Where(node=>node!=properties))
            {
                Require(run.Name==W+"r");
                var font=run.Element(W+"rPr");
                var runStyle=style;
                TextStyle(ref runStyle,font);
                foreach(var token in run.Elements().Where(node=>node!=font))
                {
                    if (token.Name==W+"t")
                    {
                        // Reserve a visible marker gutter in a real label, and
                        // keep its text as a normal paragraph in the callers.
                        var label=token.Value;
                        Require(marker!=null && spaces==0 && index==paragraphs.Length-1 &&
                            label.Length<=160 && !label.Any(Char.IsControl));
                        spaces=label.TakeWhile(c=>c==' ').Count();
                        Require(spaces>=2 && spaces<=24 && spaces+1<label.Length &&
                            "-–—".Contains(label[spaces]) && label[spaces+1]==' ');
                        labelStyle=runStyle;
                    }
                    else
                    {
                        var drawing=FloatingDrawingChoice(token);
                        Require(marker==null && index==0 && drawing.Name==W+"drawing");
                        var propertiesNode=drawing.Element(WP+"anchor");
                        var description=propertiesNode==null ? null : propertiesNode.Element(WP+"docPr");
                        Require(description==null || String.IsNullOrWhiteSpace((string)description.Attribute("descr")));
                        marker=ReadFloatingLayer(drawing,0);
                    }
                }
            }
        }
        Require(marker!=null && spaces>0 && marker.Shape.Element(S+"txbx")==null &&
            marker.Ink.Left>=0 && marker.Ink.Width>=4 && marker.Ink.Width<=48 &&
            marker.Ink.Height>=4 && marker.Ink.Height<=40);
        var labelHeight=FloatingLineHeight(labelStyle);
        Require(marker.Ink.Top<labelTop+labelHeight && marker.Ink.Bottom>labelTop+labelHeight/4 &&
            marker.Ink.Top>=labelTop-labelHeight && marker.Ink.Bottom<=labelTop+2*labelHeight &&
            (labelStyle.Align=="left" || labelStyle.Align=="both"));
        float textStart;
        using(var measure=new Bitmap(1,1))
        using(var surface=Graphics.FromImage(measure))
        using(var format=(StringFormat)StringFormat.GenericTypographic.Clone())
        using(var font=new Font(labelStyle.Family,labelStyle.Size,labelStyle.FontFlags,GraphicsUnit.Pixel))
        {
            surface.PageUnit=GraphicsUnit.Pixel;
            format.FormatFlags|=StringFormatFlags.NoWrap | StringFormatFlags.MeasureTrailingSpaces;
            var origin=labelStyle.Left+labelStyle.Indent;
            textStart=origin+TextWidth(surface,font,format,new String(' ',spaces),labelStyle.Gap,labelStyle.WidthScale);
            Require(origin>=0 && Math.Abs(marker.Ink.Left-origin)<=labelHeight &&
                Math.Abs(marker.Ink.Right-textStart)<=labelHeight/2);
        }
        var top=marker.Ink.Top-.5f;
        var width=Math.Max(textStart,marker.Ink.Right+1);
        return PaintFloatingLayers(new[]{marker},0,top,width,marker.Ink.Bottom+.5f,true);
    }

    private byte[] RenderFloatingScene(XElement scene)
    {
        var paragraphs=scene.Elements().Take(33).ToArray();
        Require(paragraphs.Length>=1 && paragraphs.Length<=32 && paragraphs.All(p=>p.Name==W+"p"));
        var defaultStyle=DefaultLabelStyle();
        var normalStyle=NormalFloatingStyle(defaultStyle);
        var layers=new List<FloatingLayer>();
        float cursor=0, priorAfter=0;
        for (int index=0;index<paragraphs.Length;index++)
        {
            var paragraph=paragraphs[index];
            var properties=paragraph.Element(W+"pPr");
            var style=FloatingParagraphStyle(defaultStyle,normalStyle,properties);
            var top=cursor+(index==0 ? 0 : Math.Max(priorAfter,style.Before));
            var before=layers.Count;
            foreach (var run in paragraph.Elements().Where(n=>n!=properties))
            {
                Require(run.Name==W+"r");
                var runProperties=run.Element(W+"rPr");
                Require(runProperties==null || runProperties.Elements().All(n=>n.Name==W+"lang" ||
                    n.Name==W+"noProof" || n.Name==W+"rFonts" || n.Name==W+"sz" || n.Name==W+"szCs" ||
                    n.Name==W+"iCs" || n.Name==W+"bCs"));
                var runStyle=style;
                TextStyle(ref runStyle,runProperties);
                if (runStyle.Size>style.Size) style=runStyle;
                foreach (var token in run.Elements().Where(n=>n!=runProperties))
                {
                    if (token.Name==W+"tab" || token.Name==W+"t" && String.IsNullOrWhiteSpace(token.Value)) continue;
                    if (token.Name==W+"lastRenderedPageBreak" && index==0 && layers.Count==0) continue;
                    var drawing=FloatingDrawingChoice(token);
                    Require(drawing.Name==W+"drawing" && layers.Count<32);
                    layers.Add(ReadFloatingLayer(drawing,top));
                }
            }
            if (index==0 || index==paragraphs.Length-1) Require(layers.Count>before);
            cursor=top+FloatingLineHeight(style);
            priorAfter=style.After;
            Require(cursor<=600);
        }
        Require(layers.Count>=2);
        var measured=layers.OrderBy(item=>item.Ink.Top).ToArray();
        var bottom=measured[0].Ink.Bottom;
        foreach(var layer in measured.Skip(1))
        {
            Require(layer.Ink.Top-bottom<=36);
            bottom=Math.Max(bottom,layer.Ink.Bottom);
        }
        // Retain the column origin when the shape has a leading inset. Crop
        // the trailing area since the following reflow has a different width.
        var left=Math.Min(0,measured.Min(item=>item.Ink.Left))-0.5f;
        var topEdge=Math.Min(0,measured[0].Ink.Top)-0.5f;
        var right=measured.Max(item=>item.Ink.Right)+0.5f;
        return PaintFloatingLayers(layers,left,topEdge,right,bottom+0.5f,false);
    }

    private byte[] PaintFloatingLayers(IEnumerable<FloatingLayer> layers,float left,float top,float right,float bottom,bool transparent)
    {
        const float scale=4;
        var width=(int)Math.Ceiling(scale*(right-left));
        var height=(int)Math.Ceiling(scale*(bottom-top));
        Require(width>=8 && width<=2048 && height>=8 && height<=2048);
        using (var bitmap=new Bitmap(width,height,PixelFormat.Format32bppArgb))
        using (var surface=Graphics.FromImage(bitmap))
        using (var encoded=new MemoryStream())
        {
            surface.Clear(transparent ? Color.Transparent : Color.White);
            surface.PageUnit=GraphicsUnit.Pixel;
            surface.SmoothingMode=SmoothingMode.AntiAlias;
            surface.TextRenderingHint=TextRenderingHint.AntiAliasGridFit;
            surface.ScaleTransform(scale,scale);
            foreach (var layer in layers.OrderBy(item=>item.Order))
                using (var matrix=new Matrix(1/EmuPerPoint,0,0,1/EmuPerPoint,layer.Left-left,layer.Top-top))
                    DrawShape(layer.Shape,matrix,surface);
            bitmap.Save(encoded,ImageFormat.Png);
            return encoded.ToArray();
        }
    }

    private byte[] RenderCanvas(XElement canvas, XElement extent, XElement effects)
    {
        var width=Number(extent,"cx")/EmuPerPoint;
        var height=Number(extent,"cy")/EmuPerPoint;
        var left=Number(effects,"l")/EmuPerPoint;
        var right=Number(effects,"r")/EmuPerPoint;
        var top=Number(effects,"t")/EmuPerPoint;
        var bottom=Number(effects,"b")/EmuPerPoint;
        Require(width>1 && width<=4000 && height>1 && height<=4000 &&
            new[]{left,right,top,bottom}.All(value=>value>=0 && value<=72));
        var background=canvas.Element(C+"bg");
        var whole=canvas.Element(C+"whole");
        Require(background==null || background.Elements().All(x=>x.Name==A+"noFill" || x.Name==A+"solidFill" || EmptyEffects(x)));
        Require(whole==null || whole.Elements().All(x=>x.Name==A+"ln" || EmptyEffects(x)));
        var scale=Math.Min(4f,2024f/Math.Max(width+left+right,height+top+bottom));
        using (var bitmap=new Bitmap((int)Math.Ceiling(scale*(width+left+right)),
                                     (int)Math.Ceiling(scale*(height+top+bottom)),PixelFormat.Format32bppArgb))
        using (var surface=Graphics.FromImage(bitmap))
        using (var fromEmu=new Matrix(1/EmuPerPoint,0,0,1/EmuPerPoint,0,0))
        using (var border=new GraphicsPath())
        using (var encoded=new MemoryStream())
        {
            surface.Clear(Color.Transparent);
            surface.PageUnit=GraphicsUnit.Pixel;
            surface.SmoothingMode=SmoothingMode.AntiAlias;
            surface.TextRenderingHint=TextRenderingHint.AntiAliasGridFit;
            surface.TranslateTransform(left*scale,top*scale);
            surface.ScaleTransform(scale,scale);
            var fill=Filled(background,null,Color.Black);
            if (fill.HasValue)
                using (var brush=new SolidBrush(fill.Value)) surface.FillRectangle(brush,0,0,width,height);
            foreach (var child in canvas.Elements())
            {
                if (child.Name==S+"wsp") DrawShape(child,fromEmu,surface);
                else if (child.Name==G+"wgp") DrawGroup(child,fromEmu,surface,0);
                else if (child.Name==P+"pic") DrawPicture(child,fromEmu,surface);
                else Require(child==background || child==whole || child.Name==C+"extLst");
            }
            border.AddRectangle(new RectangleF(0,0,width,height));
            if (whole!=null) DrawStroke(surface,border,whole.Element(A+"ln"),null,Color.Black,false);
            bitmap.Save(encoded,ImageFormat.Png);
            return encoded.ToArray();
        }
    }

    private static Bitmap CropVmlCanvas(Bitmap bitmap,Rectangle content,int padding)
    {
        var bounds=content;
        var data=bitmap.LockBits(new Rectangle(Point.Empty,bitmap.Size),ImageLockMode.ReadOnly,PixelFormat.Format32bppArgb);
        try
        {
            var pixels=new byte[bitmap.Width*4];
            for (var y=0;y<bitmap.Height;y++)
            {
                Marshal.Copy(IntPtr.Add(data.Scan0,y*data.Stride),pixels,0,pixels.Length);
                for (var x=0;x<bitmap.Width;x++)
                    if (!bounds.Contains(x,y) &&
                        (pixels[x*4]!=255 || pixels[x*4+1]!=255 || pixels[x*4+2]!=255))
                        bounds=Rectangle.Union(bounds,new Rectangle(x,y,1,1));
            }
        }
        finally { bitmap.UnlockBits(data); }
        // A group can paint beyond its nominal rectangle. Keep the overhang,
        // and fall back to the source markup if the drawing hits our canvas.
        Require(bounds.Left>0 && bounds.Top>0 && bounds.Right<bitmap.Width && bounds.Bottom<bitmap.Height);
        bounds.Inflate(padding,padding);
        return bitmap.Clone(Rectangle.Intersect(bounds,new Rectangle(Point.Empty,bitmap.Size)),PixelFormat.Format32bppArgb);
    }

    private byte[] RenderAutoFitTextBox(XElement shape, XElement properties, XElement body, float width, float height)
    {
        var box=shape.Element(S+"txbx");
        var content=box==null ? null : box.Element(W+"txbxContent");
        var geometry=properties.Element(A+"prstGeom");
        var stroke=properties.Element(A+"ln");
        Require(content!=null && content.HasElements && content.Elements().All(x=>x.Name==W+"p") &&
            content.Descendants(W+"t").Any(x=>!String.IsNullOrWhiteSpace(x.Value)) &&
            shape.Elements().All(x=>x==box || x==properties || x==body || x.Name==S+"cNvPr" || x.Name==S+"cNvSpPr") &&
            geometry!=null && (string)geometry.Attribute("prst")=="rect" &&
            !geometry.Descendants(A+"gd").Any() && properties.Element(A+"noFill")!=null &&
            stroke!=null && stroke.Elements().Count()==1 && stroke.Element(A+"noFill")!=null &&
            properties.Elements().All(x=>x==geometry || x==stroke || x.Name==A+"xfrm" ||
                x.Name==A+"noFill" || x.Name==A+"extLst") &&
            body.Elements().Count()==1 && body.Element(A+"spAutoFit").Attributes().All(x=>x.IsNamespaceDeclaration) &&
            !On(body,"anchorCtr") &&
            Number(body,"rot")==0 && Number(body,"numCol",1)==1 &&
            ((string)body.Attribute("vert")??"horz")=="horz" && ((string)body.Attribute("anchor")??"t")=="t" &&
            ((string)body.Attribute("wrap")??"square")=="square");
        var margins=new[]{"lIns","tIns","rIns","bIns"}.Select((side,i)=>
            Number(body,side,i%2==0 ? 91440 : 45720)/EmuPerPoint).ToArray();
        var available=width-margins[0]-margins[2];
        Require(available>=1 && margins.All(value=>value>=0));
        var fonts=new Dictionary<Tuple<string,float,FontStyle>,Font>();
        using (var format=(StringFormat)StringFormat.GenericTypographic.Clone())
        using (var measurements=new Bitmap(1,1))
        using (var measure=Graphics.FromImage(measurements))
        try
        {
            measure.PageUnit=GraphicsUnit.Pixel;
            measure.TextRenderingHint=TextRenderingHint.AntiAliasGridFit;
            format.FormatFlags|=StringFormatFlags.NoWrap|StringFormatFlags.MeasureTrailingSpaces;
            float fittedHeight;
            var lines=LayoutLabel(content.Elements(W+"p"),DefaultLabelStyle(),available,fonts,measure,format,out fittedHeight);
            Require(lines.All(line=>line.Left>=0 && line.Right>=0 && line.Offset>=0));
            // Exact leading can be shorter than the last glyph's line height.
            fittedHeight=Math.Max(fittedHeight,lines.Max(line=>line.Offset+line.Height*1.25f));
            height=Math.Max(height,margins[1]+fittedHeight+margins[3]);
            Require(height<=4000);
            // A small text frame should keep its physical size in reading flow.
            const float dpi=96f/72;
            const int padding=2;
            var scale=Math.Min(dpi,2024f/Math.Max(width,height));
            using (var bitmap=new Bitmap((int)Math.Ceiling(width*scale)+2*padding,
                (int)Math.Ceiling(height*scale)+2*padding,PixelFormat.Format32bppArgb))
            using (var surface=Graphics.FromImage(bitmap))
            using (var encoded=new MemoryStream())
            {
                surface.Clear(Color.White);
                surface.PageUnit=GraphicsUnit.Pixel;
                surface.TextRenderingHint=TextRenderingHint.AntiAliasGridFit;
                surface.TranslateTransform(padding,padding);
                surface.ScaleTransform(scale,scale);
                PaintLabel(lines,margins[0],margins[1],available,surface,format);
                bitmap.Save(encoded,ImageFormat.Png);
                return encoded.ToArray();
            }
        }
        finally { foreach (var font in fonts.Values) font.Dispose(); }
    }

    private void DrawGroup(XElement group, Matrix parent, Graphics surface, int depth)
    {
        Require(depth < 16);
        var props = group.Element(G + "grpSpPr");
        Require(props != null && props.Elements().All(x => x.Name == A+"xfrm" || x.Name == A+"extLst"));
        float width, height;
        using (var frame = Frame(props.Element(A + "xfrm"), true, out width, out height))
        {
            frame.Multiply(parent,MatrixOrder.Append);
            foreach (var child in group.Elements())
            {
                if (child.Name == G + "grpSp") DrawGroup(child,frame,surface,depth+1);
                else if (child.Name == S + "wsp") DrawShape(child,frame,surface);
                else if (child.Name == P + "pic") DrawPicture(child,frame,surface);
                else Require(child == props || child.Name == G+"cNvGrpSpPr" || child.Name == G+"cNvPr" ||
                             child.Name == G+"nvGrpSpPr" || child.Name == G+"extLst");
            }
        }
    }

    private static float CropOffset(XElement crop, string edge)
    {
        var value=crop==null ? null : (string)crop.Attribute(edge);
        if (value==null) return 0;
        value=value.Trim();
        var percent=value.EndsWith("%",StringComparison.Ordinal);
        decimal offset;
        Require(Decimal.TryParse(percent ? value.Substring(0,value.Length-1) : value,
            NumberStyles.AllowLeadingSign | NumberStyles.AllowDecimalPoint, CultureInfo.InvariantCulture,out offset));
        offset/=percent ? 100 : 100000;
        Require(offset>=-4 && offset<1);
        return (float)offset;
    }

    private static Bitmap RasterizeEmbeddedEmf(Metafile image)
    {
        // Crop and color adjustments operate on pixels. Decode the complete
        // vector first, preserving its frame within the drawing size limit.
        Require(image.Width>0 && image.Height>0 && image.GetMetafileHeader().IsEmfOrEmfPlus());
        var scale=Math.Min(1.0,4096.0/Math.Max(image.Width,image.Height));
        var width=Math.Max(1,(int)Math.Floor(image.Width*scale));
        var height=Math.Max(1,(int)Math.Floor(image.Height*scale));
        var bitmap=new Bitmap(width,height,PixelFormat.Format32bppPArgb);
        try
        {
            using (var surface=Graphics.FromImage(bitmap)) surface.DrawImage(image,0,0,width,height);
            return bitmap;
        }
        catch
        {
            bitmap.Dispose();
            throw;
        }
    }

    private static Image ReadEmbeddedPicture(Stream input, byte[] bytes)
    {
        var enhanced=bytes.Length>=44 && bytes[0]==1 && bytes[1]==0 && bytes[2]==0 && bytes[3]==0 &&
            bytes[40]==0x20 && bytes[41]==0x45 && bytes[42]==0x4d && bytes[43]==0x46;
        if (!enhanced) return Image.FromStream(input,false,true);
        Require(HomeLibDoc.HasCompleteEmf(input));
        using (var decoded=Image.FromStream(input,false,true))
        {
            var metafile=decoded as Metafile;
            Require(metafile!=null);
            return RasterizeEmbeddedEmf(metafile);
        }
    }

    private void DrawPicture(XElement picture, Matrix parent, Graphics surface)
    {
        var props=picture.Element(P+"spPr");
        var fill=picture.Element(P+"blipFill");
        Require(++objects<=128 && props!=null && fill!=null && picture.Elements().All(x =>
            x==props || x==fill || x.Name==P+"nvPicPr"));
        var geometry=props.Element(A+"prstGeom");
        var outline=props.Element(A+"ln");
        Require(geometry!=null && (string)geometry.Attribute("prst")=="rect" && !geometry.Descendants(A+"gd").Any() &&
            (outline==null || outline.Elements().Count()==1 && outline.Element(A+"noFill")!=null) &&
            props.Elements().All(x => x==geometry || x==outline || x.Name==A+"xfrm" || x.Name==A+"noFill" || x.Name==A+"extLst"));
        var blip=fill.Element(A+"blip");
        var stretch=fill.Element(A+"stretch");
        var crop=fill.Element(A+"srcRect");
        Require(blip!=null && stretch!=null && fill.Elements().All(x=>x==blip || x==stretch || x==crop) &&
            stretch.Elements().All(x=>x.Name==A+"fillRect" && !x.HasAttributes) &&
            blip.Elements().All(x=>x.Name==A+"grayscl" || x.Name==A+"extLst"));
        var id=(string)blip.Attribute(R+"embed");
        Require(!String.IsNullOrEmpty(id) && blip.Attribute(R+"link")==null);
        var assets=figure.Elements("asset").Where(x=>(string)x.Attribute("id")==id).Take(2).ToArray();
        Require(assets.Length==1 && assets[0].Value.Length<=8*1024*1024);
        var bytes=Convert.FromBase64String(assets[0].Value);
        float width,height;
        using (var frame=Frame(props.Element(A+"xfrm"),false,out width,out height))
        using (var input=new MemoryStream(bytes,false))
        using (var image=ReadEmbeddedPicture(input,bytes))
        using (var attributes=new ImageAttributes())
        {
            Require(width>0 && height>0 && image.Width>0 && image.Height>0 &&
                (long)image.Width*image.Height<=16*1024*1024 &&
                (image.RawFormat.Guid==ImageFormat.Jpeg.Guid || image.RawFormat.Guid==ImageFormat.Png.Guid ||
                 image.RawFormat.Guid==ImageFormat.MemoryBmp.Guid));
            frame.Multiply(parent,MatrixOrder.Append);
            var left=CropOffset(crop,"l"); var top=CropOffset(crop,"t");
            var right=1-CropOffset(crop,"r"); var bottom=1-CropOffset(crop,"b");
            var x1=Math.Max(0,left); var x2=Math.Min(1,right);
            var y1=Math.Max(0,top); var y2=Math.Min(1,bottom);
            Require(x1<x2 && y1<y2);
            var source=RectangleF.FromLTRB(x1*image.Width,y1*image.Height,x2*image.Width,y2*image.Height);
            var destination=RectangleF.FromLTRB((x1-left)/(right-left)*width,(y1-top)/(bottom-top)*height,
                (x2-left)/(right-left)*width,(y2-top)/(bottom-top)*height);
            var corners=new[]{new PointF(destination.Left,destination.Top),new PointF(destination.Right,destination.Top),
                new PointF(destination.Left,destination.Bottom)};
            frame.TransformPoints(corners);
            if (blip.Element(A+"grayscl")!=null)
                attributes.SetColorMatrix(new ColorMatrix(new[]{new[]{.299f,.299f,.299f,0f,0f},
                    new[]{.587f,.587f,.587f,0f,0f},new[]{.114f,.114f,.114f,0f,0f},
                    new[]{0f,0f,0f,1f,0f},new[]{0f,0f,0f,0f,1f}}));
            attributes.SetWrapMode(WrapMode.TileFlipXY);
            var state=surface.Save();
            try
            {
                surface.InterpolationMode=InterpolationMode.HighQualityBicubic;
                surface.DrawImage(image,corners,source,GraphicsUnit.Pixel,attributes);
            }
            finally { surface.Restore(state); }
        }
    }

    private static IEnumerable<XElement> GeometryPaths(XElement custom)
    {
        Require(custom != null && custom.Element(A + "pathLst") != null);
        return custom.Element(A + "pathLst").Elements(A + "path");
    }

    private static void DrawCustomPath(GraphicsPath output, XElement source, float width, float height,bool fillOnly=false)
    {
        var w=Number(source,"w"); var h=Number(source,"h");
        Require(w>0 && h>0 && source.Elements().Count()<=4096 &&
                source.Attributes().All(x => x.Name=="w" || x.Name=="h" || fillOnly && x.Name=="stroke"));
        var current = new PointF();
        bool started=false;
        foreach (var command in source.Elements())
        {
            var points=command.Elements(A + "pt").Select(p =>
                new PointF((float)Number(p,"x")/w*width,(float)Number(p,"y")/h*height)).ToArray();
            if (command.Name == A+"moveTo" && points.Length==1)
            {
                output.StartFigure(); current=points[0]; started=true;
            }
            else if (started && command.Name == A+"lnTo" && points.Length==1)
            {
                output.AddLine(current,points[0]); current=points[0];
            }
            else if (started && command.Name == A+"cubicBezTo" && points.Length==3)
            {
                output.AddBezier(current,points[0],points[1],points[2]); current=points[2];
            }
            else if (started && command.Name == A+"close" && points.Length==0)
            {
                output.CloseFigure(); started=false;
            }
            else Require(false);
        }
    }

    private Color DrawingColor(XElement node, Color placeholder)
    {
        Require(node != null);
        var value = (string)node.Attribute("val");
        Color color;
        if (node.Name == A+"schemeClr")
        {
            if (value == "phClr") color = placeholder;
            else
            {
                var key=value;
                if (key=="tx1") key="t1";
                if (key=="tx2") key="t2";
                if (key=="hlink") key="hyperlink";
                if (key=="folHlink") key="followedHyperlink";
                var mapped = colors!=null && key!=null ? (string)colors.Attribute(W+key) : null;
                switch (mapped ?? key)
                {
                    case "t1": case "dark1": key="dk1"; break;
                    case "t2": case "dark2": key="dk2"; break;
                    case "bg1": case "light1": key="lt1"; break;
                    case "bg2": case "light2": key="lt2"; break;
                    case "hyperlink": key="hlink"; break;
                    case "followedHyperlink": key="folHlink"; break;
                    default: key=mapped ?? key; break;
                }
                var scheme=theme==null ? null : theme.Descendants(A+"clrScheme").FirstOrDefault();
                var entry=scheme==null ? null : scheme.Elements().FirstOrDefault(e => e.Name.LocalName==key);
                if (entry!=null)
                {
                    var definition=entry.Elements().FirstOrDefault();
                    Require(definition!=null && (definition.Name==A+"srgbClr" || definition.Name==A+"sysClr"));
                    color=DrawingColor(definition,Color.Black);
                }
                else { Require(key=="dk1" || key=="lt1"); color=key=="lt1" ? Color.White : Color.Black; }
            }
        }
        else
        {
            Require(node.Name == A+"srgbClr" || node.Name == A+"sysClr");
            if (node.Name == A+"sysClr") value=(string)node.Attribute("lastClr");
            int rgb=0;
            Require(value!=null && value.Length==6 && Int32.TryParse(value,NumberStyles.HexNumber,
                CultureInfo.InvariantCulture,out rgb));
            color=Color.FromArgb(unchecked((int)0xff000000)|rgb);
        }
        foreach (var modifier in node.Elements())
        {
            var fraction=Number(modifier,"val")/100000f;
            if (modifier.Name==A+"alpha")
            { Require(fraction>=0 && fraction<=1); color=Color.FromArgb((int)Math.Round(255*fraction),color); }
            else if (modifier.Name==A+"satMod")
            {
                Require(fraction>=0);
                var saturation=color.GetSaturation();
                if (saturation==0) continue;
                var midpoint=255*color.GetBrightness();
                var scale=Math.Min(fraction,1/saturation);
                color=Color.FromArgb(color.A,(int)Math.Round(midpoint+(color.R-midpoint)*scale),
                    (int)Math.Round(midpoint+(color.G-midpoint)*scale),(int)Math.Round(midpoint+(color.B-midpoint)*scale));
            }
            else if (modifier.Name==A+"shade")
            {
                Require(fraction>=0 && fraction<=1);
                color=Color.FromArgb(color.A,(int)Math.Round(color.R*fraction),
                    (int)Math.Round(color.G*fraction),(int)Math.Round(color.B*fraction));
            }
            else Require(false);
        }
        return color;
    }

    private XElement ThemeStyle(XElement reference, string list)
    {
        var index=Number(reference,"idx");
        if (index==0) return null;
        var entries=theme==null ? null : theme.Descendants(A+list).FirstOrDefault();
        var style=entries==null || index<1 ? null : entries.Elements().ElementAtOrDefault(index-1);
        Require(style!=null);
        return style;
    }

    private Color? Filled(XElement parent, XElement fallback, Color placeholder)
    {
        var fills=new[]{A+"solidFill",A+"noFill",A+"gradFill",A+"blipFill",A+"pattFill",A+"grpFill"};
        var fill=parent==null ? null : parent.Elements().FirstOrDefault(x => fills.Contains(x.Name));
        if (fill==null) fill=fallback;
        if (fill==null || fill.Name==A+"noFill") return null;
        Require(fill.Name==A+"solidFill");
        return DrawingColor(fill.Elements().SingleOrDefault(),placeholder);
    }

    private static bool EmptyEffects(XElement element)
    {
        return element.Name==A+"effectLst" && !element.HasElements && String.IsNullOrWhiteSpace(element.Value) &&
            element.Attributes().All(attribute=>attribute.IsNamespaceDeclaration);
    }

    private static bool IsStraightLine(XElement preset)
    {
        var name=(string)(preset==null ? null : preset.Attribute("prst"));
        return name=="line" || name=="straightConnector1";
    }

    private void DrawStroke(Graphics surface, GraphicsPath path, XElement line, XElement style, Color lineBase, bool arrowPath)
    {
        if (line==null && style==null) return;
        Require(new[]{line,style}.Where(e=>e!=null).SelectMany(e=>e.Elements()).All(e=>
            e.Name==A+"noFill" || e.Name==A+"solidFill" || e.Name==A+"prstDash" && (string)e.Attribute("val")=="solid" ||
            e.Name==A+"miter" && Number(e,"lim",800000)==800000 || e.Name==A+"round" && !e.HasElements ||
            e.Name==A+"bevel" && !e.HasElements ||
            (e.Name==A+"headEnd" || e.Name==A+"tailEnd") && SupportedLineEnd(e,arrowPath)));
        var inherited=style==null ? null : style.Element(A+"solidFill");
        var color=Filled(line,inherited,lineBase);
        var weight=Number(line,"w",Number(style,"w",9525))/EmuPerPoint;
        Require(weight>=0 && weight<=30);
        if (!color.HasValue || weight==0) return;
        using (var pen=new Pen(color.Value,weight))
        {
            var joinNames=new[]{A+"round",A+"bevel",A+"miter"};
            var join=new[]{line,style}.Where(node=>node!=null).SelectMany(node=>node.Elements())
                .FirstOrDefault(node=>joinNames.Contains(node.Name));
            if (join!=null)
            {
                if (join.Name==A+"round") pen.LineJoin=LineJoin.Round;
                else if (join.Name==A+"bevel") pen.LineJoin=LineJoin.Bevel;
                else pen.MiterLimit=Number(join,"lim",800000)/100000f;
            }
            var cap=(string)(line==null ? null : line.Attribute("cap")) ?? (string)(style==null ? null : style.Attribute("cap"));
            if (cap=="rnd") pen.StartCap=pen.EndCap=LineCap.Round;
            else if (cap=="sq") pen.StartCap=pen.EndCap=LineCap.Square;
            else Require(cap==null || cap=="flat");
            surface.DrawPath(pen,path);
            if (arrowPath)
            {
                var ends=path.PathPoints;
                DrawArrow(StrokeChild(line,style,"headEnd"),ends[0],ends[1],pen,surface);
                DrawArrow(StrokeChild(line,style,"tailEnd"),ends[ends.Length-1],ends[ends.Length-2],pen,surface);
            }
        }
    }

    private void DrawShape(XElement shape, Matrix parent, Graphics surface,bool rotate=true)
    {
        var props=shape.Element(S+"spPr");
        Require(++objects<=128 && props!=null && shape.Elements().All(x => x==props ||
            x.Name==S+"cNvPr" || x.Name==S+"cNvSpPr" || x.Name==S+"cNvCnPr" ||
            x.Name==S+"txbx" || x.Name==S+"bodyPr" || x.Name==S+"style" || x.Name==S+"extLst"));
        Require(props.Elements().All(x => EmptyEffects(x) || new[]{"xfrm","prstGeom","custGeom","solidFill","noFill","ln","extLst"}
            .Contains(x.Name.LocalName) && x.Name.Namespace==A));
        float width,height;
        using (var frame = Frame(props.Element(A+"xfrm"),false,out width,out height,rotate))
        using (var path = new GraphicsPath(FillMode.Alternate))
        using (var sector = new GraphicsPath(FillMode.Alternate))
        {
            frame.Multiply(parent,MatrixOrder.Append);
            var preset=props.Element(A+"prstGeom");
            if (preset==null)
            {
                foreach (var item in GeometryPaths(props.Element(A+"custGeom")))
                {
                    var fillOnly=figure.Element(V+"group")!=null && (string)item.Attribute("stroke")=="0";
                    DrawCustomPath(fillOnly ? sector : path,item,width,height,fillOnly);
                }
            }
            else
            {
                Require(!preset.Descendants(A+"gd").Any());
                var rectangle=new RectangleF(0,0,width,height);
                switch ((string)preset.Attribute("prst"))
                {
                    case "rect": path.AddRectangle(rectangle); break;
                    case "roundRect": AddRoundedRectangle(path,width,height); break;
                    case "ellipse": path.AddEllipse(rectangle); break;
                    case "line": case "straightConnector1": path.AddLine(0,0,width,height); break;
                    default: Require(false); break;
                }
            }
            Require(path.PointCount>0);
            path.Transform(frame);
            var style=shape.Element(S+"style");
            var line=props.Element(A+"ln");
            var lineRef=style==null ? null : style.Element(A+"lnRef");
            var fillRef=style==null ? null : style.Element(A+"fillRef");
            if (style!=null && props.Element(A+"effectLst")==null)
            {
                var effect=ThemeStyle(style.Element(A+"effectRef"),"effectStyleLst");
                Require(effect==null || effect.Elements().All(EmptyEffects));
            }
            var fillStyle=ThemeStyle(fillRef,"fillStyleLst");
            var fillBase=fillStyle==null ? Color.Black : DrawingColor(fillRef.Elements().FirstOrDefault(),Color.Black);
            var fill=Filled(props,fillStyle,fillBase);
            if (fill.HasValue)
            {
                if (sector.PointCount>0) sector.Transform(frame);
                using (var brush=new SolidBrush(fill.Value)) surface.FillPath(brush,sector.PointCount>0 ? sector : path);
            }
            var stroke=ThemeStyle(lineRef,"lnStyleLst");
            var arrowPath=IsStraightLine(preset) || preset==null && figure.Element(V+"group")!=null && path.PointCount>=2;
            var lineBase=stroke==null ? Color.Black : DrawingColor(lineRef.Elements().FirstOrDefault(),Color.Black);
            DrawStroke(surface,path,line,stroke,lineBase,arrowPath);
            DrawLabel(shape, frame, surface, width, height);
        }
    }

    private static void AddRoundedRectangle(GraphicsPath path,float width,float height)
    {
        Require(width>0 && height>0);
        var corner=Math.Min(width,height)/3f;
        path.AddArc(0,0,corner,corner,180,90);
        path.AddArc(width-corner,0,corner,corner,270,90);
        path.AddArc(width-corner,height-corner,corner,corner,0,90);
        path.AddArc(0,height-corner,corner,corner,90,90);
        path.CloseFigure();
    }

    private static bool SupportedLineEnd(XElement node,bool straight)
    {
        var kind=(string)node.Attribute("type")??"none";
        if (straight && kind=="stealth")
            return new[]{"sm","med"}.Contains((string)node.Attribute("w")??"med") &&
                ((string)node.Attribute("len")??"med")=="med";
        return kind=="none" || straight && (kind=="arrow" || kind=="triangle") &&
            ((string)node.Attribute("w")??"med")=="med" && ((string)node.Attribute("len")??"med")=="med";
    }

    private static XElement StrokeChild(XElement direct,XElement inherited,string name)
    {
        var child=direct==null ? null : direct.Element(A+name);
        return child ?? (inherited==null ? null : inherited.Element(A+name));
    }

    private static void DrawArrow(XElement marker,PointF end,PointF start,Pen pen,Graphics surface)
    {
        var kind=marker==null ? null : (string)marker.Attribute("type");
        if (kind!="arrow" && kind!="stealth" && kind!="triangle") return;
        var dx=start.X-end.X;
        var dy=start.Y-end.Y;
        var distance=(float)Math.Sqrt(dx*dx+dy*dy);
        Require(distance>0);
        var length=Math.Min(pen.Width*8,distance/2);
        var halfWidth=length*((string)marker.Attribute("w")=="sm" ? .32f : .5f);
        var x=dx/distance;
        var y=dy/distance;
        var left=new PointF(end.X+x*length-y*halfWidth,end.Y+y*length+x*halfWidth);
        var right=new PointF(end.X+x*length+y*halfWidth,end.Y+y*length-x*halfWidth);
        if (kind=="stealth" || kind=="triangle")
            using (var brush=new SolidBrush(pen.Color))
                surface.FillPolygon(brush,kind=="triangle" ? new[]{left,end,right} :
                    new[]{left,end,right,new PointF(end.X+x*length*.72f,end.Y+y*length*.72f)});
        else surface.DrawLines(pen,new[]{left,end,right});
    }

    private void DrawLabel(XElement shape, Matrix frame, Graphics surface, float width, float height)
    {
        var box=shape.Element(S+"txbx");
        if (box==null) return;
        var content=box.Element(W+"txbxContent");
        Require(content!=null && content.Elements().All(x => x.Name==W+"p" || x.Name==W+"tbl"));
        var paragraphs=content.Elements(W+"p").ToArray();
        var tables=content.Elements(W+"tbl").ToArray();
        if (tables.Length==0 && !content.Descendants(W+"sym").Any() &&
            !content.Descendants(W+"t").Any(t=>t.Value.Length!=0) &&
            !content.Descendants(W+"drawing").Any() && !content.Descendants(W+"pict").Any()) return;
        var body=shape.Element(S+"bodyPr");
        Require(body!=null && Number(body,"rot")==0 && Number(body,"numCol",1)==1 &&
                ((string)body.Attribute("vert")??"horz")=="horz" &&
                body.Elements().All(x => x.Name==A+"noAutofit" || x.Name==A+"prstTxWarp" && (string)x.Attribute("prst")=="textNoShape"));
        var coordinate=frame.Elements;
        Require(Math.Abs(coordinate[1])+Math.Abs(coordinate[2])<0.00001f && coordinate[0]>0 && coordinate[3]>0);
        var left=Number(body,"lIns",91440)/EmuPerPoint;
        var right=Number(body,"rIns",91440)/EmuPerPoint;
        var top=Number(body,"tIns",45720)/EmuPerPoint;
        var bottom=Number(body,"bIns",45720)/EmuPerPoint;
        var preset=shape.Element(S+"spPr").Element(A+"prstGeom");
        if (preset!=null && (string)preset.Attribute("prst")=="ellipse")
        {
            // The text rectangle meets the ellipse at 45 degrees.
            const float inset=0.14644661f;
            var horizontal=width*coordinate[0]*inset;
            var vertical=height*coordinate[3]*inset;
            left+=horizontal; right+=horizontal;
            top+=vertical; bottom+=vertical;
        }
        var available=new RectangleF(coordinate[4]+left,coordinate[5]+top,
            width*coordinate[0]-left-right,height*coordinate[3]-top-bottom);
        Require(available.Width>0 && available.Height>0);
        if (tables.Length>0)
        {
            Require(tables.Length==1);
            DrawTable(tables[0],body,available,surface);
            return;
        }
        var defaultWidth=styles==null ? null : styles.Element(W+"docDefaults");
        if ((defaultWidth!=null && defaultWidth.Descendants(W+"w").Any()) ||
            content.Descendants().Any(n=>n.Name==W+"pStyle" || n.Name==W+"rStyle" || n.Name==W+"hyperlink" ||
            n.Name==W+"rFonts" || n.Name==W+"sz" || n.Name==W+"w" || n.Name==W+"b" || n.Name==W+"i" || n.Name==W+"u" ||
            n.Name==W+"shd" || n.Name==W+"tabs" || n.Name==W+"drawing" || n.Name==W+"sym" || n.Name==W+"vertAlign" ||
            n.Name==W+"br" || n.Name==W+"cr" || n.Name==W+"pict" ||
            n.Name==W+"spacing" && n.Parent.Name==W+"pPr"))
        {
            DrawStyledLabel(paragraphs,body,available,surface,coordinate[5]+height*coordinate[3]);
            return;
        }
        var defaults=styles==null ? null : styles.Element(W+"docDefaults");
        var fontDefault=defaults==null ? null : defaults.Descendants(W+"rPr").FirstOrDefault();
        var familyNode=fontDefault==null ? null : fontDefault.Element(W+"rFonts");
        var family=familyNode==null ? "Times New Roman" : ((string)familyNode.Attribute(W+"ascii")??"Times New Roman");
        var size=fontDefault==null ? 12 : Number(fontDefault.Element(W+"sz"),W+"val",24)/2f;
        Require(size>=4 && size<=72);
        using (var font=new Font(family,size,FontStyle.Regular,GraphicsUnit.Pixel))
        using (var format=(StringFormat)StringFormat.GenericTypographic.Clone())
        {
            Require(String.Equals(font.FontFamily.Name,family,StringComparison.OrdinalIgnoreCase));
            format.FormatFlags |= StringFormatFlags.NoWrap | StringFormatFlags.MeasureTrailingSpaces;
            var lines=new List<Tuple<string,float,StringAlignment>>();
            foreach (var paragraph in paragraphs)
            {
                var prop=paragraph.Element(W+"pPr");
                Require(prop==null || prop.Elements().All(x => x.Name==W+"jc" || x.Name==W+"ind" && x.Attributes().All(a => a.Name==W+"firstLine" && a.Value=="0")));
                var jc=prop==null ? null : prop.Element(W+"jc");
                var align=jc==null ? "left" : (string)jc.Attribute(W+"val");
                Require(align=="left" || align=="center" || align=="right");
                var alignment=align=="center" ? StringAlignment.Center : align=="right" ? StringAlignment.Far : StringAlignment.Near;
                var runs=paragraph.Elements(W+"r").ToArray();
                Require(paragraph.Elements().All(x=>x==prop || x.Name==W+"r"));
                var gap=0f;
                foreach (var run in runs)
                {
                    Require(run.Elements().All(x=>x.Name==W+"rPr" || x.Name==W+"t"));
                    var runProps=run.Element(W+"rPr");
                    Require(runProps==null || runProps.Elements().All(x => x.Name==W+"lang" || x.Name==W+"spacing"));
                    var spacing=runProps==null ? 0 : Number(runProps.Element(W+"spacing"),W+"val")/20f;
                    Require(Math.Abs(spacing)<size/3 && (run==runs[0] || spacing==gap));
                    gap=spacing;
                }
                var text=String.Concat(runs.SelectMany(r=>r.Elements(W+"t")).Select(t=>t.Value));
                characters+=text.Length;
                Require(characters<=4096 && text.All(c=>!Char.IsControl(c)));
                string line="";
                foreach (var word in text.Split(' '))
                {
                    var next=line.Length==0 ? word : line+" "+word;
                    if (line.Length>0 && TextWidth(surface,font,format,next,gap)>available.Width)
                    { lines.Add(Tuple.Create(line,gap,alignment)); line=word; }
                    else line=next;
                }
                lines.Add(Tuple.Create(line,gap,alignment));
            }
            var step=font.Size*1.15f;
            var anchor=(string)body.Attribute("anchor")??"t";
            Require(anchor=="t" || anchor=="ctr" || anchor=="b");
            var remaining=Math.Max(0,available.Height-step*lines.Count);
            var y=available.Y+(anchor=="ctr" ? remaining/2 : anchor=="b" ? remaining : 0);
            foreach (var line in lines)
            {
                var text=line.Item1; var gap=line.Item2;
                var measured=TextWidth(surface,font,format,text,gap);
                Require(measured<=available.Width+1);
                var free=available.Width-measured;
                var x=available.X+(line.Item3==StringAlignment.Center ? free/2 : line.Item3==StringAlignment.Far ? free : 0);
                if (gap==0) surface.DrawString(text,font,Brushes.Black,new PointF(x,y),format);
                else foreach (var glyph in TextElements(text))
                {
                    surface.DrawString(glyph,font,Brushes.Black,new PointF(x,y),format);
                    x+=TextWidth(surface,font,format,glyph,0)+gap;
                }
                y+=step;
            }
        }
    }

    private struct LabelStyle
    {
        public string Family;
        public float Size, Gap, WidthScale, Left, Right, Indent, Before, After, LineSpacing;
        public string LineRule;
        public int Script;
        public FontStyle FontFlags;
        public bool SmallCaps;
        public Color Color;
        public string Align;
    }

    private sealed class LabelRun
    {
        public string Text;
        public Font Font;
        public Color Color;
        public float Gap, Width;
        public float WidthScale = 1f;
        public bool Discretionary;
        public XElement Picture;
        public float PictureHeight, Rise;
        public float Height { get { return Picture==null ? Font.Size : PictureHeight; } }
    }

    private sealed class LabelWord
    {
        public readonly List<LabelRun> Runs=new List<LabelRun>();
        public float Width;
        public bool Space, Tab, HardBreak;
        public string TabLeader;
    }

    private sealed class LabelLine
    {
        public readonly List<LabelWord> Words=new List<LabelWord>();
        public float Width, Height, Depth, Left, Right, Offset;
        public string Align;
        public bool Last;
    }

    private sealed class WordTableCell
    {
        public float X, Width, Left, Top, Right, Bottom, Height;
        public string Align;
        public int Rotation;
        public int LastRow, Span;
        public bool FirstColumn, LastColumn;
        public Color Fill;
        public XElement Borders, FinalBorders;
        public List<LabelLine> Lines;
    }

    private sealed class WordTableRow
    {
        public float Height;
        public readonly List<WordTableCell> Cells=new List<WordTableCell>();
    }

    private static string WordValue(XElement element,string fallback)
    {
        return element==null ? fallback : ((string)element.Attribute(W+"val")??fallback);
    }

    private static float TableTwips(XElement property)
    {
        Require(property!=null && (string)property.Attribute(W+"type")=="dxa");
        return Number(property,W+"w")/20f;
    }

    private static float TableMargin(XElement local,XElement defaults,string edge,float fallback)
    {
        var value=local==null ? null : local.Element(W+edge);
        if (value==null && defaults!=null) value=defaults.Element(W+edge);
        var result=value==null ? fallback : TableTwips(value);
        Require(result>=0 && result<=100);
        return result;
    }

    private static Color WordRgb(string value,Color automatic)
    {
        if (value=="auto") return automatic;
        int rgb=0;
        Require(value!=null && value.Length==6 && Int32.TryParse(value,NumberStyles.HexNumber,
            CultureInfo.InvariantCulture,out rgb));
        return Color.FromArgb(unchecked((int)0xff000000)|rgb);
    }

    private static void DrawCellBorders(WordTableCell cell,XElement tableBorders,RectangleF bounds,
        bool firstRow,bool lastRow,Graphics surface)
    {
        var edges=new[]{"top","left","bottom","right"};
        Require(cell.Borders==null || cell.Borders.Elements().All(n=>n.Name.Namespace==W && edges.Contains(n.Name.LocalName)));
        foreach (var edge in edges)
        {
            var properties=edge=="bottom" ? cell.FinalBorders : cell.Borders;
            var border=properties==null ? null : properties.Element(W+edge);
            if (border==null && tableBorders!=null)
            {
                var outside=edge=="top" ? firstRow : edge=="bottom" ? lastRow :
                    edge=="left" ? cell.FirstColumn : cell.LastColumn;
                var tableEdge=outside ? edge : (edge=="top" || edge=="bottom" ? "insideH" : "insideV");
                border=tableBorders.Element(W+tableEdge);
            }
            if (border==null) continue;
            var kind=WordValue(border,"none");
            if (kind=="nil" || kind=="none") continue;
            Require(kind=="single" && Number(border,W+"space")==0 &&
                border.Attributes().All(a=>a.Name==W+"val" || a.Name==W+"sz" || a.Name==W+"space" || a.Name==W+"color"));
            var weight=Number(border,W+"sz",4)/8f;
            Require(weight>0 && weight<=12);
            using (var pen=new Pen(WordRgb((string)border.Attribute(W+"color")??"auto",Color.Black),weight))
            {
                if (edge=="top") surface.DrawLine(pen,bounds.Left,bounds.Top,bounds.Right,bounds.Top);
                else if (edge=="left") surface.DrawLine(pen,bounds.Left,bounds.Top,bounds.Left,bounds.Bottom);
                else if (edge=="bottom") surface.DrawLine(pen,bounds.Left,bounds.Bottom,bounds.Right,bounds.Bottom);
                else surface.DrawLine(pen,bounds.Right,bounds.Top,bounds.Right,bounds.Bottom);
            }
        }
    }

    private WordTableCell LayoutTableCell(XElement node,float x,float width,float rowHeight,XElement defaults,
        LabelStyle labelStyle,Dictionary<Tuple<string,float,FontStyle>,Font> fonts,Graphics surface,StringFormat format)
    {
        var properties=node.Element(W+"tcPr");
        Require(node.Elements().All(n=>n==properties || n.Name==W+"p"));
        Require(properties==null || properties.Elements().All(n=>n.Name==W+"tcW" || n.Name==W+"gridSpan" ||
            n.Name==W+"tcBorders" || n.Name==W+"shd" || n.Name==W+"tcMar" || n.Name==W+"vAlign" ||
            n.Name==W+"textDirection" || n.Name==W+"vMerge"));
        var cell=new WordTableCell { X=x, Width=width, Align="top", Fill=Color.White };
        var local=properties==null ? null : properties.Element(W+"tcMar");
        cell.Left=TableMargin(local,defaults,"left",5.4f);
        cell.Right=TableMargin(local,defaults,"right",5.4f);
        cell.Top=TableMargin(local,defaults,"top",0);
        cell.Bottom=TableMargin(local,defaults,"bottom",0);
        if (properties!=null)
        {
            var preferred=properties.Element(W+"tcW");
            if (preferred!=null && (string)preferred.Attribute(W+"type")!="auto")
                Require(Math.Abs(TableTwips(preferred)-width)<2);
            cell.Borders=properties.Element(W+"tcBorders");
            cell.FinalBorders=cell.Borders;
            var align=properties.Element(W+"vAlign");
            if (align!=null) cell.Align=(string)align.Attribute(W+"val");
            var direction=WordValue(properties.Element(W+"textDirection"),"lrTb");
            Require(direction=="lrTb" || direction=="tbRl" || direction=="btLr");
            cell.Rotation=direction=="btLr" ? -90 : direction=="tbRl" ? 90 : 0;
            var shading=properties.Element(W+"shd");
            if (shading!=null)
            {
                Require((string)shading.Attribute(W+"val")=="clear" &&
                    shading.Attributes().All(a=>a.Name==W+"val" || a.Name==W+"fill" || a.Name==W+"color"));
                cell.Fill=WordRgb((string)shading.Attribute(W+"fill")??"auto",Color.White);
            }
        }
        Require(cell.Align=="top" || cell.Align=="center" || cell.Align=="bottom");
        var textWidth=cell.Rotation==0 ? width-cell.Left-cell.Right : rowHeight-cell.Top-cell.Bottom;
        Require(textWidth>0);
        cell.Lines=LayoutLabel(node.Elements(W+"p"),labelStyle,textWidth,fonts,surface,format,out cell.Height);
        return cell;
    }

    private static bool SameCellSide(XElement first,XElement second,string side)
    {
        var a=first==null ? null : first.Element(W+side);
        var b=second==null ? null : second.Element(W+side);
        return XNode.DeepEquals(a,b);
    }

    private void PaintCell(WordTableCell cell,RectangleF bounds,Graphics surface,StringFormat format)
    {
        var normal=cell.Rotation==0;
        var forward=cell.Rotation>0;
        var width=normal ? bounds.Width-cell.Left-cell.Right : bounds.Height-cell.Top-cell.Bottom;
        var height=normal ? bounds.Height-cell.Top-cell.Bottom : bounds.Width-cell.Left-cell.Right;
        var start=normal ? cell.Left : forward ? cell.Top : cell.Bottom;
        var top=normal ? cell.Top : forward ? cell.Right : cell.Left;
        var remaining=Math.Max(0,height-cell.Height);
        var contentTop=top+(cell.Align=="center" ? remaining/2 : cell.Align=="bottom" ? remaining : 0);
        var last=cell.Lines.LastOrDefault();
        Require(last==null || contentTop-top+last.Offset+last.Height<=height+1);
        if (normal)
        {
            PaintLabel(cell.Lines,bounds.Left+start,bounds.Top+contentTop,width,surface,format);
            return;
        }
        var state=surface.Save();
        try
        {
            surface.TranslateTransform(forward ? bounds.Right : bounds.Left,
                forward ? bounds.Top : bounds.Bottom);
            surface.RotateTransform(cell.Rotation);
            PaintLabel(cell.Lines,start,contentTop,width,surface,format);
        }
        finally { surface.Restore(state); }
    }

    private void ApplyTableStyle(string identity,XElement properties,ref LabelStyle label,int depth=0)
    {
        Require(depth<24);
        var style=WordStyle(identity);
        Require(style!=null && (string)style.Attribute(W+"type")=="table" &&
            !style.Elements().Any(n=>n.Name==W+"tblStylePr" || n.Name==W+"trPr" || n.Name==W+"tcPr"));
        var parent=style.Element(W+"basedOn");
        if (parent!=null) ApplyTableStyle(WordValue(parent,""),properties,ref label,depth+1);
        ParagraphStyle(ref label,style.Element(W+"pPr"));
        TextStyle(ref label,style.Element(W+"rPr"));
        var defaults=style.Element(W+"tblPr");
        if (defaults==null) return;
        foreach(var item in defaults.Elements())
        {
            var old=properties.Element(item.Name);
            if (old!=null) old.Remove();
            properties.Add(new XElement(item));
        }
    }

    private static float[] AutoTableWidths(XElement table,int columns)
    {
        var widths=new float[columns];
        foreach (var row in table.Elements(W+"tr"))
        {
            var cells=row.Elements(W+"tc").ToArray();
            Require(cells.Length==columns);
            for (var index=0;index<columns;index++)
            {
                var cell=cells[index].Element(W+"tcPr");
                Require(cell!=null && cell.Element(W+"vMerge")==null && cell.Element(W+"gridSpan")==null);
                var width=TableTwips(cell.Element(W+"tcW"));
                Require(width>0 && (widths[index]==0 || Math.Abs(widths[index]-width)<.01f));
                widths[index]=width;
            }
        }
        return widths;
    }

    private void DrawTable(XElement table,XElement body,RectangleF available,Graphics surface)
    {
        var direct=table.Element(W+"tblPr");
        var grid=table.Element(W+"tblGrid");
        Require(direct!=null && grid!=null && table.Elements().All(n=>n==direct || n==grid || n.Name==W+"tr"));
        var style=DefaultLabelStyle();
        var properties=new XElement(W+"tblPr");
        var styleId=direct.Element(W+"tblStyle");
        if (styleId!=null) ApplyTableStyle(WordValue(styleId,""),properties,ref style);
        foreach (var item in direct.Elements().Where(n=>n!=styleId))
        {
            var old=properties.Element(item.Name);
            if (old!=null) old.Remove();
            properties.Add(new XElement(item));
        }
        Require(properties.Elements().All(n=>n.Name==W+"tblW" || n.Name==W+"tblInd" || n.Name==W+"jc" ||
            n.Name==W+"tblLayout" || n.Name==W+"tblCellMar" || n.Name==W+"tblLook" || n.Name==W+"tblBorders"));
        var layout=properties.Element(W+"tblLayout");
        var layoutType=layout==null ? "autofit" : (string)layout.Attribute(W+"type");
        Require((layoutType=="fixed" || layoutType=="autofit") && grid.Elements().All(n=>n.Name==W+"gridCol"));
        var widths=grid.Elements(W+"gridCol").Select(n=>Number(n,W+"w")/20f).ToArray();
        Require(widths.Length>0 && widths.Length<=64 && widths.All(value=>value>0));
        if (layoutType=="autofit") widths=AutoTableWidths(table,widths.Length);
        var width=widths.Sum();
        var horizontalOverflow=(string)body.Attribute("horzOverflow")=="overflow";
        Require(width<=available.Width+1 || horizontalOverflow && width<=4000);
        var preferred=properties.Element(W+"tblW");
        if (preferred!=null && (string)preferred.Attribute(W+"type")!="auto")
            Require(Math.Abs(TableTwips(preferred)-width)<2);
        var indent=properties.Element(W+"tblInd");
        var defaultAlign=WordValue(properties.Element(W+"jc"),"left");
        var margins=properties.Element(W+"tblCellMar");
        var borders=properties.Element(W+"tblBorders");
        Require(borders==null || borders.Elements().All(n=>n.Name.Namespace==W &&
            new[]{"top","left","bottom","right","insideH","insideV"}.Contains(n.Name.LocalName)));
        var verticalOverflow=(string)body.Attribute("vertOverflow")=="overflow";
        var fonts=new Dictionary<Tuple<string,float,FontStyle>,Font>();
        var rows=new List<WordTableRow>();
        var previousMerges=new Dictionary<int,WordTableCell>();
        using (var format=(StringFormat)StringFormat.GenericTypographic.Clone())
        try
        {
            format.FormatFlags|=StringFormatFlags.NoWrap|StringFormatFlags.MeasureTrailingSpaces;
            foreach (var row in table.Elements(W+"tr"))
            {
                var rowProps=row.Element(W+"trPr");
                Require(rows.Count<64 && row.Elements().All(n=>n==rowProps || n.Name==W+"tc"));
                Require(rowProps==null || rowProps.Elements().All(n=>n.Name==W+"trHeight" || n.Name==W+"jc" ||
                    n.Name==W+"cantSplit"));
                var align=WordValue(rowProps==null ? null : rowProps.Element(W+"jc"),defaultAlign);
                Require(align=="left" || align=="center" || align=="right");
                var free=available.Width-width;
                var result=new WordTableRow();
                var height=rowProps==null ? null : rowProps.Element(W+"trHeight");
                var rule=height==null ? "auto" : ((string)height.Attribute(W+"hRule")??"auto");
                Require(rule=="exact" || rule=="atLeast" || rule=="auto");
                var specified=Number(height,W+"val")/20f;
                var column=0;
                var merges=new Dictionary<int,WordTableCell>();
                var x=available.X+(align=="center" ? free/2 :
                    align=="right" ? free : (indent==null ? 0 : TableTwips(indent)));
                foreach (var cell in row.Elements(W+"tc"))
                {
                    var cellProps=cell.Element(W+"tcPr");
                    var span=Number(cellProps==null ? null : cellProps.Element(W+"gridSpan"),W+"val",1);
                    Require(span>0 && column+span<=widths.Length);
                    var cellWidth=widths.Skip(column).Take(span).Sum();
                    var item=LayoutTableCell(cell,x,cellWidth,specified,margins,style,fonts,surface,format);
                    item.Span=span;
                    item.FirstColumn=column==0;
                    item.LastColumn=column+span==widths.Length;
                    item.LastRow=rows.Count;
                    var merge=cellProps==null ? null : cellProps.Element(W+"vMerge");
                    var mergeMode=merge==null ? "" : WordValue(merge,"continue");
                    if (mergeMode=="continue")
                    {
                        WordTableCell origin;
                        Require(previousMerges.TryGetValue(column,out origin) && origin.Span==span &&
                            item.Lines.All(line=>line.Words.Count==0) && origin.Rotation==0 && item.Rotation==0 &&
                            Math.Abs(item.X-origin.X)<.01f && origin.Fill.ToArgb()==item.Fill.ToArgb() &&
                            SameCellSide(origin.Borders,item.Borders,"left") &&
                            SameCellSide(origin.Borders,item.Borders,"right"));
                        origin.LastRow=rows.Count;
                        origin.FinalBorders=item.Borders;
                        merges.Add(column,origin);
                    }
                    else
                    {
                        Require(mergeMode=="" || mergeMode=="restart");
                        if (mergeMode=="restart")
                        {
                            Require(rule=="exact");
                            merges.Add(column,item);
                        }
                        result.Cells.Add(item);
                    }
                    x+=cellWidth;
                    column+=span;
                }
                Require(column==widths.Length);
                var fit=result.Cells.Select(c=>c.Rotation==0 ? c.Top+c.Height+c.Bottom : specified)
                    .DefaultIfEmpty(0).Max();
                result.Height=rule=="exact" ? specified : Math.Max(fit,specified);
                Require(result.Height>0 && result.Height<=4000);
                rows.Add(result);
                previousMerges=merges;
            }
            var tableHeight=rows.Sum(row=>row.Height);
            Require(rows.Count>0 && tableHeight<=4000 && (verticalOverflow || tableHeight<=available.Height+1));
            var anchor=(string)body.Attribute("anchor")??"t";
            Require(anchor=="t" || anchor=="ctr" || anchor=="b");
            float before,after;
            var leading=LayoutLabel(table.ElementsBeforeSelf(W+"p"),style,available.Width,fonts,surface,format,out before);
            var trailing=LayoutLabel(table.ElementsAfterSelf(W+"p"),style,available.Width,fonts,surface,format,out after);
            // Word anchors the text box's block, including the paragraph mark
            // that follows its table.
            var boxSpace=available.Height-before-tableHeight-after;
            var top=available.Y+before+(anchor=="ctr" ? boxSpace/2 : anchor=="b" ? boxSpace : 0);
            var y=top;
            for (var rowIndex=0;rowIndex<rows.Count;rowIndex++)
            {
                var row=rows[rowIndex];
                foreach (var cell in row.Cells)
                {
                    var height=rows.Skip(rowIndex).Take(cell.LastRow-rowIndex+1).Sum(segment=>segment.Height);
                    var bounds=new RectangleF(cell.X,y,cell.Width,height);
                    using (var brush=new SolidBrush(cell.Fill)) surface.FillRectangle(brush,bounds);
                }
                y+=row.Height;
            }
            y=top;
            for (var rowIndex=0;rowIndex<rows.Count;rowIndex++)
            {
                var row=rows[rowIndex];
                foreach (var cell in row.Cells)
                {
                    var height=rows.Skip(rowIndex).Take(cell.LastRow-rowIndex+1).Sum(segment=>segment.Height);
                    var bounds=new RectangleF(cell.X,y,cell.Width,height);
                    DrawCellBorders(cell,borders,bounds,rowIndex==0,cell.LastRow==rows.Count-1,surface);
                    PaintCell(cell,bounds,surface,format);
                }
                y+=row.Height;
            }
            PaintLabel(leading,available.X,top-before,available.Width,surface,format);
            PaintLabel(trailing,available.X,top+tableHeight,available.Width,surface,format);
        }
        finally { foreach (var font in fonts.Values) font.Dispose(); }
    }

    private XElement WordStyle(string id)
    {
        if (String.IsNullOrEmpty(id) || styles==null) return null;
        return styles.Elements(W+"style").FirstOrDefault(s=>(string)s.Attribute(W+"styleId")==id);
    }

    private void InheritStyle(ref LabelStyle value,string id,bool paragraph,int depth=0)
    {
        Require(depth<24);
        var style=WordStyle(id);
        Require(style!=null && (string)style.Attribute(W+"type")== (paragraph ? "paragraph" : "character"));
        var basedOn=style.Element(W+"basedOn");
        if (basedOn!=null) InheritStyle(ref value,(string)basedOn.Attribute(W+"val"),paragraph,depth+1);
        if (paragraph) ParagraphStyle(ref value,style.Element(W+"pPr"));
        TextStyle(ref value,style.Element(W+"rPr"));
    }

    private static void ParagraphStyle(ref LabelStyle value,XElement properties,bool singleParagraph=false,bool directNumbering=false)
    {
        if (properties==null) return;
        foreach (var node in properties.Elements())
        {
            if (node.Name==W+"spacing")
            {
                var keys=new[]{W+"before",W+"after",W+"line",W+"lineRule"};
                Require(node.Attributes().All(a=>keys.Contains(a.Name)));
                if (node.Attribute(W+"before")!=null) value.Before=Number(node,W+"before")/20f;
                if (node.Attribute(W+"after")!=null) value.After=Number(node,W+"after")/20f;
                if (node.Attribute(W+"line")!=null) value.LineSpacing=Number(node,W+"line");
                value.LineRule=(string)node.Attribute(W+"lineRule")??value.LineRule;
                Require(value.LineRule=="auto" || value.LineRule=="exact" || value.LineRule=="atLeast");
            }
            else if (node.Name==W+"ind")
            {
                var keys=new[]{W+"left",W+"right",W+"firstLine",W+"hanging"};
                Require(node.Attributes().All(a=>keys.Contains(a.Name)));
                if (node.Attribute(W+"left")!=null) value.Left=Number(node,W+"left")/20f;
                if (node.Attribute(W+"right")!=null) value.Right=Number(node,W+"right")/20f;
                if (node.Attribute(W+"firstLine")!=null) value.Indent=Number(node,W+"firstLine")/20f;
                if (node.Attribute(W+"hanging")!=null) value.Indent=-Number(node,W+"hanging")/20f;
            }
            else if (node.Name==W+"jc")
            {
                value.Align=(string)node.Attribute(W+"val");
                Require(new[]{"left","right","center","both"}.Contains(value.Align));
            }
            else if (node.Name==W+"shd")
            {
                Require((string)node.Attribute(W+"val")=="clear" &&
                    new[]{"FFFFFF","auto"}.Contains((string)node.Attribute(W+"fill")) &&
                    node.Attributes().All(a=>a.Name==W+"val" || a.Name==W+"fill" || a.Name==W+"color"));
            }
            else if (node.Name==W+"tabs" || singleParagraph && node.Name==W+"contextualSpacing" ||
                     directNumbering && node.Name==W+"numPr") continue;
            else if (node.Name==W+"autoSpaceDE" || node.Name==W+"autoSpaceDN" || node.Name==W+"adjustRightInd")
            {
                Require(WordValue(node,"1")=="0" || WordValue(node,"1")=="false");
            }
            else Require(node.Name==W+"pStyle" || node.Name==W+"rPr" || node.Name==W+"widowControl" ||
                node.Name==W+"suppressAutoHyphens" || node.Name==W+"keepNext" || node.Name==W+"keepLines" ||
                node.Name==W+"outlineLvl");
        }
    }

    private string ThemeLatinFont(string token)
    {
        Require(theme!=null && new[]{"majorAscii","majorHAnsi","minorAscii","minorHAnsi"}.Contains(token));
        var elements=theme.Element(A+"themeElements");
        var scheme=elements==null ? null : elements.Element(A+"fontScheme");
        var group=scheme==null ? null : scheme.Element(A+(token.StartsWith("major",StringComparison.Ordinal) ?
            "majorFont" : "minorFont"));
        var latin=group==null ? null : group.Element(A+"latin");
        var family=latin==null ? null : (string)latin.Attribute("typeface");
        Require(!String.IsNullOrWhiteSpace(family));
        return family;
    }

    private void TextStyle(ref LabelStyle value,XElement properties)
    {
        if (properties==null) return;
        foreach (var node in properties.Elements())
        {
            if (node.Name==W+"rFonts")
            {
                var kind=(string)node.Attribute(W+"ascii")??(string)node.Attribute(W+"hAnsi");
                var themed=(string)node.Attribute(W+"asciiTheme")??(string)node.Attribute(W+"hAnsiTheme");
                if (themed!=null) kind=ThemeLatinFont(themed);
                if (kind!=null) value.Family=kind;
            }
            else if (node.Name==W+"sz") value.Size=Number(node,W+"val")/2f;
            else if (node.Name==W+"spacing") value.Gap=Number(node,W+"val")/20f;
            else if (node.Name==W+"color")
            {
                Require(node.Attributes().All(a=>a.Name==W+"val"));
                var color=(string)node.Attribute(W+"val");
                if (color=="auto") value.Color=Color.Black;
                else
                {
                    int rgb=0;
                    Require(color!=null && color.Length==6 && Int32.TryParse(color,NumberStyles.HexNumber,
                        CultureInfo.InvariantCulture,out rgb));
                    value.Color=Color.FromArgb(unchecked((int)0xff000000)|rgb);
                }
            }
            else if (node.Name==W+"b" || node.Name==W+"i" || node.Name==W+"u")
            {
                var yes=(string)node.Attribute(W+"val");
                var flag=node.Name==W+"b" ? FontStyle.Bold : node.Name==W+"i" ? FontStyle.Italic : FontStyle.Underline;
                bool on=yes==null || yes=="1" || yes=="true" || yes=="single";
                Require(on || yes=="none" || yes=="0" || yes=="false");
                value.FontFlags=on ? value.FontFlags|flag : value.FontFlags&~flag;
            }
            else if (node.Name==W+"smallCaps")
            {
                var flag=WordValue(node,"1");
                Require(flag=="0" || flag=="1" || flag=="false" || flag=="true");
                value.SmallCaps=flag=="1" || flag=="true";
            }
            else if (node.Name==W+"w")
            {
                var percent=Number(node,W+"val",100);
                Require(percent>=1 && percent<=600);
                value.WidthScale=percent/100f;
            }
            else if (node.Name==W+"vertAlign")
            {
                var alignment=WordValue(node,"baseline");
                Require(alignment=="baseline" || alignment=="superscript" || alignment=="subscript");
                value.Script=alignment=="superscript" ? 1 : alignment=="subscript" ? -1 : 0;
            }
            else if (node.Name==W+"position") Require(Number(node,W+"val")==0);
            else if (node.Name==W+"strike") Require(WordValue(node,"1")=="0" || WordValue(node,"1")=="false");
            else Require(new[]{W+"rStyle",W+"bCs",W+"iCs",W+"szCs",W+"lang",W+"noProof"}.Contains(node.Name));
        }
    }

    private LabelStyle DefaultLabelStyle()
    {
        // A legacy Word textbox without an explicit font size uses 20 half-points.
        var defaultStyle=new LabelStyle { Family="Times New Roman", Size=figure.Element(W+"pict")!=null ? 10 : 12, Color=Color.Black,
            Align="left", LineRule="auto", LineSpacing=240, WidthScale=1f };
        var defaults=styles==null ? null : styles.Element(W+"docDefaults");
        if (defaults!=null)
        {
            ParagraphStyle(ref defaultStyle,defaults.Descendants(W+"pPr").FirstOrDefault());
            TextStyle(ref defaultStyle,defaults.Descendants(W+"rPr").FirstOrDefault());
        }
        return defaultStyle;
    }

    private void DrawStyledLabel(XElement[] paragraphs, XElement body, RectangleF available, Graphics surface,float shapeBottom)
    {
        var fonts=new Dictionary<Tuple<string,float,FontStyle>,Font>();
        using (var format=(StringFormat)StringFormat.GenericTypographic.Clone())
        try
        {
            format.FormatFlags|=StringFormatFlags.NoWrap|StringFormatFlags.MeasureTrailingSpaces;
            float height;
            var lines=LayoutLabel(paragraphs,DefaultLabelStyle(),available.Width,fonts,surface,format,out height,
                ((string)body.Attribute("wrap")??"square")=="square");
            var anchor=(string)body.Attribute("anchor")??"t";
            Require(anchor=="t" || anchor=="ctr" || anchor=="b");
            var remaining=Math.Max(0,available.Height-height);
            var y=available.Y+(anchor=="ctr" ? remaining/2 : anchor=="b" ? remaining : 0);
            if (figure.Element("floating")!=null)
            {
                var painted=lines.Where(line=>line.Words.Any(word=>!word.Space && !word.Tab))
                    .Select(line=>line.Offset+line.Height+line.Depth).DefaultIfEmpty(0).Max();
                Require(y+painted<=shapeBottom+1);
            }
            if (figure.Descendants(W+"tbl").Any() && (string)body.Attribute("vertOverflow")!="overflow")
            {
                var state=surface.Save();
                try
                {
                    surface.SetClip(available,CombineMode.Intersect);
                    PaintLabel(lines,available.X,y,available.Width,surface,format);
                }
                finally { surface.Restore(state); }
            }
            else PaintLabel(lines,available.X,y,available.Width,surface,format);
        }
        finally { foreach (var font in fonts.Values) font.Dispose(); }
    }

    private XElement BulletLevel(XElement properties)
    {
        var spec=properties==null ? null : properties.Element(W+"numPr");
        if (spec==null) return null;
        Require(spec.Elements().All(n=>n.Name==W+"numId" || n.Name==W+"ilvl"));
        var numberId=WordValue(spec.Element(W+"numId"),"");
        if (numberId=="0") return null;
        var levelId=WordValue(spec.Element(W+"ilvl"),"0");
        Require(numbering!=null && numberId.Length>0 && Regex.IsMatch(levelId,"^[0-8]$"));
        var instance=numbering.Elements(W+"num").FirstOrDefault(n=>(string)n.Attribute(W+"numId")==numberId);
        Require(instance!=null);
        var definitionId=WordValue(instance.Element(W+"abstractNumId"),"");
        var definition=numbering.Elements(W+"abstractNum").FirstOrDefault(n=>(string)n.Attribute(W+"abstractNumId")==definitionId);
        Require(definition!=null);
        var local=instance.Elements(W+"lvlOverride").FirstOrDefault(n=>(string)n.Attribute(W+"ilvl")==levelId);
        var level=local==null ? null : local.Element(W+"lvl");
        level=level??definition.Elements(W+"lvl").FirstOrDefault(n=>(string)n.Attribute(W+"ilvl")==levelId);
        Require(level!=null && WordValue(level.Element(W+"numFmt"),"")=="bullet" &&
            WordValue(level.Element(W+"lvlJc"),"left")=="left" && level.Element(W+"lvlPicBulletId")==null);
        return level;
    }

    private List<LabelLine> LayoutLabel(IEnumerable<XElement> paragraphs,LabelStyle defaultStyle,float width,
        Dictionary<Tuple<string,float,FontStyle>,Font> fonts,Graphics surface,StringFormat format,out float height,
        bool wrapLongWords=false)
    {
        var lines=new List<LabelLine>();
        height=0;
        var blocks=paragraphs as XElement[] ?? paragraphs.ToArray();
        foreach (var paragraph in blocks)
        {
            var style=defaultStyle;
            var properties=paragraph.Element(W+"pPr");
            var pStyle=properties==null ? null : properties.Element(W+"pStyle");
            if (pStyle!=null) InheritStyle(ref style,(string)pStyle.Attribute(W+"val"),true);
            else if (styles!=null)
            {
                var defaultParagraph=styles.Elements(W+"style").FirstOrDefault(n=>(string)n.Attribute(W+"type")=="paragraph" &&
                    new[]{"1","true"}.Contains((string)n.Attribute(W+"default")));
                if (defaultParagraph!=null) InheritStyle(ref style,(string)defaultParagraph.Attribute(W+"styleId"),true);
            }
            var bullet=BulletLevel(properties);
            var listProperties=bullet==null ? null : bullet.Element(W+"pPr");
            ParagraphStyle(ref style,listProperties);
            ParagraphStyle(ref style,properties,blocks.Length==1,true);
            height+=style.Before;
            var words=LabelWords(paragraph,properties,style,fonts,surface,format);
            if (bullet!=null)
            {
                var marker=WordValue(bullet.Element(W+"lvlText"),"");
                var suffix=WordValue(bullet.Element(W+"suff"),"tab");
                Require(marker.Length>0 && marker.Length<=32 && !marker.Any(Char.IsControl) &&
                    (suffix=="tab" || suffix=="space" || suffix=="nothing"));
                var markerStyle=style;
                TextStyle(ref markerStyle,bullet.Element(W+"rPr"));
                var prefix=new List<LabelWord>();
                AppendLabelWords(prefix,marker+(suffix=="tab" ? "\t" : suffix=="space" ? " " : ""),
                    markerStyle,fonts,surface,format);
                words.InsertRange(0,prefix);
            }
            var line=new LabelLine { Left=style.Left+style.Indent, Right=style.Right, Align=style.Align };
            foreach (var next in words)
            {
                var word=next;
                if (word.HardBreak)
                {
                    height=AddLabelLine(lines,line,style,height,true);
                    line=new LabelLine { Left=style.Left, Right=style.Right, Align=style.Align };
                    continue;
                }
                if (word.Space && line.Words.Count==0) continue;
                if (word.Tab) SetTabWidth(word,properties,listProperties,line.Left+line.Width);
                while (!word.Space && !word.Tab && line.Width+word.Width>width-line.Left-line.Right)
                {
                    LabelWord beginning, tail;
                    var space=width-line.Left-line.Right-line.Width;
                    if (SplitDiscretionary(word,space,out beginning,out tail) ||
                        wrapLongWords && line.Words.Count==0 && SplitLongLabelWord(word,space,surface,format,out beginning,out tail))
                    {
                        AppendWord(line,beginning);
                        word=tail;
                    }
                    else if (line.Words.Count==0) break;
                    height=AddLabelLine(lines,line,style,height,false);
                    line=new LabelLine { Left=style.Left, Right=style.Right, Align=style.Align };
                }
                AppendWord(line,word);
            }
            height=AddLabelLine(lines,line,style,height,true)+style.After;
            Require(height>=0 && height<=12000);
        }
        return lines;
    }

    private static void SetTabWidth(LabelWord tab,XElement properties,XElement listProperties,float position)
    {
        var stops=properties==null ? null : properties.Element(W+"tabs");
        if (stops==null && listProperties!=null) stops=listProperties.Element(W+"tabs");
        var stop=stops==null ? null : stops.Elements(W+"tab").Where(n=>Number(n,W+"pos")/20f>position)
            .OrderBy(n=>Number(n,W+"pos")).FirstOrDefault();
        if (stop==null)
        {
            tab.Width=(float)((Math.Floor(position/36)+1)*36)-position;
            return;
        }
        var alignment=WordValue(stop,"left");
        Require(alignment=="left" || alignment=="num" && listProperties!=null);
        // Older DOC conversions can leave the binary TBD leader bits in the attribute.
        switch ((string)stop.Attribute(W+"leader")??"none")
        {
            case "none": break;
            case "8": case "dot": tab.TabLeader="."; break;
            case "16": case "hyphen": tab.TabLeader="-"; break;
            case "24": case "underscore": tab.TabLeader="_"; break;
            case "middleDot": tab.TabLeader="\u00b7"; break;
            default: throw new UnsupportedDrawing();
        }
        tab.Width=Number(stop,W+"pos")/20f-position;
    }

    private static void AppendWord(LabelLine line,LabelWord word)
    {
        line.Words.Add(word);
        line.Width+=word.Width;
        line.Height=Math.Max(line.Height,word.Runs.Max(r=>r.Height+Math.Max(0,r.Rise)));
        line.Depth=Math.Max(line.Depth,word.Runs.Max(r=>Math.Max(0,-r.Rise)));
    }

    private static bool SplitDiscretionary(LabelWord word,float space,out LabelWord first,out LabelWord rest)
    {
        first=null; rest=null;
        var split=-1;
        var width=0f;
        for (var index=0;index<word.Runs.Count-1;index++)
        {
            var run=word.Runs[index];
            if (!run.Discretionary) width+=run.Width;
            else if (width>0 && width+run.Width<=space) split=index;
        }
        if (split<0) return false;
        var marker=word.Runs[split];
        first=new LabelWord();
        first.Runs.AddRange(word.Runs.Take(split));
        first.Runs.Add(new LabelRun { Text=marker.Text,Font=marker.Font,Color=marker.Color,
            Gap=marker.Gap,Width=marker.Width,WidthScale=marker.WidthScale,Rise=marker.Rise });
        first.Width=first.Runs.Where(r=>!r.Discretionary).Sum(r=>r.Width);
        rest=new LabelWord();
        rest.Runs.AddRange(word.Runs.Skip(split+1));
        rest.Width=rest.Runs.Where(r=>!r.Discretionary).Sum(r=>r.Width);
        return true;
    }

    private static LabelRun MeasureLabelFragment(LabelRun source,string text,Graphics surface,StringFormat format)
    {
        return new LabelRun { Text=text,Font=source.Font,Color=source.Color,Gap=source.Gap,Rise=source.Rise,
            WidthScale=source.WidthScale,Width=TextWidth(surface,source.Font,format,text,source.Gap,source.WidthScale) };
    }

    private static bool SplitLongLabelWord(LabelWord word,float space,Graphics surface,StringFormat format,
        out LabelWord first,out LabelWord rest)
    {
        first=new LabelWord(); rest=new LabelWord();
        for (var index=0;index<word.Runs.Count;index++)
        {
            var run=word.Runs[index];
            if (run.Discretionary || first.Width+run.Width<=space)
            {
                first.Runs.Add(run);
                if (!run.Discretionary) first.Width+=run.Width;
                continue;
            }
            if (run.Picture==null)
            {
                var elements=StringInfo.ParseCombiningCharacters(run.Text);
                var low=0; var high=elements.Length-1;
                while (low<high)
                {
                    var middle=(low+high+1)/2;
                    var fragment=MeasureLabelFragment(run,run.Text.Substring(0,elements[middle]),surface,format);
                    if (first.Width+fragment.Width<=space) low=middle;
                    else high=middle-1;
                }
                if (low>0)
                {
                    var cut=elements[low];
                    var fragment=MeasureLabelFragment(run,run.Text.Substring(0,cut),surface,format);
                    first.Runs.Add(fragment);
                    first.Width+=fragment.Width;
                    rest.Runs.Add(MeasureLabelFragment(run,run.Text.Substring(cut),surface,format));
                    index++;
                }
            }
            rest.Runs.AddRange(word.Runs.Skip(index));
            rest.Width=rest.Runs.Where(item=>!item.Discretionary).Sum(item=>item.Width);
            return first.Width>0 && rest.Width>0;
        }
        return false;
    }

    private void PaintLabel(IEnumerable<LabelLine> lines,float left,float top,float width,
        Graphics surface,StringFormat format)
    {
        foreach (var line in lines)
        {
            var free=width-line.Left-line.Right-line.Width;
            Require(free>=-1);
            var x=left+line.Left+(line.Align=="center" ? free/2 : line.Align=="right" ? free : 0);
            var spaces=line.Words.Count(w=>w.Space);
            var justify=!line.Last && line.Align=="both" && spaces>0 ? free/spaces : 0;
            foreach (var word in line.Words)
            {
                if (word.Tab)
                {
                    var source=word.Runs[0];
                    if (word.TabLeader!=null)
                    {
                        var leader=new LabelRun { Text=word.TabLeader, Font=source.Font, Color=source.Color,
                            WidthScale=source.WidthScale, Rise=source.Rise };
                        var advance=Math.Max(1,TextWidth(surface,leader.Font,format,leader.Text,0,leader.WidthScale));
                        using (var brush=new SolidBrush(leader.Color))
                            for (var step=0f;step+advance<=word.Width;step+=advance)
                                DrawRun(surface,format,leader,brush,x+step,
                                    top+line.Offset+Math.Max(0,line.Height-leader.Height)-leader.Rise);
                    }
                    x+=word.Width;
                    continue;
                }
                foreach (var run in word.Runs)
                {
                    if (run.Discretionary) continue;
                    var y=top+line.Offset+Math.Max(0,line.Height-run.Height)-run.Rise;
                    if (run.Picture!=null)
                        using (var toLine=new Matrix(1/EmuPerPoint,0,0,1/EmuPerPoint,x,y))
                            DrawPicture(run.Picture,toLine,surface);
                    else
                        using (var brush=new SolidBrush(run.Color))
                            DrawRun(surface,format,run,brush,x,y);
                    x+=run.Width;
                }
                if (word.Space) x+=justify;
            }
        }
    }

    private static LabelWord InlineLabelPicture(XElement run,XElement drawing)
    {
        var properties=run.Element(W+"rPr");
        Require(run.Elements().All(n=>n==properties || n==drawing) &&
            (properties==null || properties.Elements().All(n=>n.Name==W+"noProof" || n.Name==W+"position" ||
                n.Name==W+"sz" || n.Name==W+"szCs" || n.Name==W+"lang")));
        var inline=drawing.Element(WP+"inline");
        Require(inline!=null && drawing.Elements().Count()==1);
        Require(inline.Elements().All(n=>n.Name==WP+"extent" || n.Name==WP+"effectExtent" ||
            n.Name==WP+"docPr" || n.Name==WP+"cNvGraphicFramePr" || n.Name==A+"graphic"));
        var effects=inline.Element(WP+"effectExtent");
        Require(effects==null || effects.Attributes().All(a=>a.IsNamespaceDeclaration || a.Value=="0"));
        Require(new[]{"distT","distB","distL","distR"}.All(side=>Number(inline,side)==0));
        var graphic=inline.Element(A+"graphic");
        var graphicData=graphic==null ? null : graphic.Element(A+"graphicData");
        var picture=graphicData==null ? null : graphicData.Element(P+"pic");
        var shape=picture==null ? null : picture.Element(P+"spPr");
        var transform=shape==null ? null : shape.Element(A+"xfrm");
        Require(transform!=null && graphic.Elements().Count()==1 && graphicData.Elements().Count()==1 &&
            (string)graphicData.Attribute("uri")==P.NamespaceName);
        var extent=inline.Element(WP+"extent");
        var imageSize=transform.Element(A+"ext");
        var offset=transform.Element(A+"off");
        Require(extent!=null && imageSize!=null && offset!=null && !transform.HasAttributes &&
            Number(offset,"x")==0 && Number(offset,"y")==0);
        var width=Number(extent,"cx");
        var height=Number(extent,"cy");
        Require(width==Number(imageSize,"cx") && height==Number(imageSize,"cy"));
        return LabelPictureWord(picture,width,height,properties);
    }

    private static LabelWord InlineVmlLabelPicture(XElement run,XElement drawing)
    {
        var properties=run.Element(W+"rPr");
        var shape=drawing.Element(V+"shape");
        Require(run.Elements().All(n=>n==properties || n==drawing) &&
            (properties==null || properties.Elements().All(n=>n.Name==W+"noProof" || n.Name==W+"position")) &&
            drawing.Elements().Count()==1 && shape!=null && (string)shape.Attribute("type")=="#_x0000_t75" &&
            shape.Attributes().All(a=>a.IsNamespaceDeclaration || a.Name=="id" || a.Name=="type" || a.Name=="style" ||
                a.Name=="filled" || a.Name=="stroked"));
        var style=VmlStyle(shape);
        Require(style.Keys.All(name=>name=="width" || name=="height"));
        var picture=ReadVmlPicture(shape,style,true);
        var size=picture.Element(P+"spPr").Element(A+"xfrm").Element(A+"ext");
        return LabelPictureWord(picture,Number(size,"cx"),Number(size,"cy"),properties);
    }

    private static LabelWord LabelPictureWord(XElement picture,int width,int height,XElement properties)
    {
        var rise=properties==null ? 0 : Number(properties.Element(W+"position"),W+"val")/2f;
        Require(width>0 && width<=720*EmuPerPoint && height>0 && height<=720*EmuPerPoint && Math.Abs(rise)<=72);
        var word=new LabelWord { Width=width/EmuPerPoint };
        word.Runs.Add(new LabelRun { Picture=picture, Width=word.Width, PictureHeight=height/EmuPerPoint, Rise=rise });
        return word;
    }

    private List<LabelWord> LabelWords(XElement paragraph,XElement properties,LabelStyle inherited,
        Dictionary<Tuple<string,float,FontStyle>,Font> fonts,Graphics surface,StringFormat format)
    {
        var words=new List<LabelWord>();
        Require(paragraph.Elements().All(n=>n==properties || n.Name==W+"r" || n.Name==W+"hyperlink"));
        foreach (var run in paragraph.Elements().Where(n=>n!=properties).SelectMany(n=>n.Name==W+"r" ? new[]{n} : n.Elements()))
        {
            Require(run.Name==W+"r");
            var drawing=run.Element(W+"drawing");
            if (drawing!=null)
            {
                words.Add(InlineLabelPicture(run,drawing));
                continue;
            }
            var legacy=run.Element(W+"pict");
            if (legacy!=null)
            {
                words.Add(InlineVmlLabelPicture(run,legacy));
                continue;
            }
            Require(run.Elements().All(n=>n.Name==W+"rPr" || n.Name==W+"t" ||
                n.Name==W+"softHyphen" || n.Name==W+"tab" || n.Name==W+"sym" || n.Name==W+"br" || n.Name==W+"cr"));
            var runStyle=inherited;
            var props=run.Element(W+"rPr");
            var rStyle=props==null ? null : props.Element(W+"rStyle");
            if (rStyle!=null) InheritStyle(ref runStyle,(string)rStyle.Attribute(W+"val"),false);
            TextStyle(ref runStyle,props);
            Require(runStyle.Size>=1 && runStyle.Size<=72 && Math.Abs(runStyle.Gap)<runStyle.Size/3);
            foreach (var segment in LabelSegments(run,runStyle))
                if (segment.Item1==null) words.Add(new LabelWord { HardBreak=true });
                else AppendLabelWords(words,segment.Item1,segment.Item2,fonts,surface,format);
        }
        return words;
    }

    private static IEnumerable<Tuple<string,LabelStyle>> LabelSegments(XElement run,LabelStyle style)
    {
        var text=new System.Text.StringBuilder();
        foreach (var item in run.Elements().Where(n=>n.Name!=W+"rPr"))
        {
            var lineBreak=item.Name==W+"br" || item.Name==W+"cr";
            if (item.Name!=W+"sym" && !lineBreak)
            {
                text.Append(item.Name==W+"t" ? item.Value : item.Name==W+"tab" ? "\t" : "\u00ad");
                continue;
            }
            if (text.Length>0)
            {
                yield return Tuple.Create(text.ToString(),style);
                text.Clear();
            }
            if (lineBreak)
            {
                Require(((string)item.Attribute(W+"type")??"textWrapping")=="textWrapping" &&
                    ((string)item.Attribute(W+"clear")??"none")=="none");
                yield return Tuple.Create((string)null,style);
                continue;
            }
            var symbol=style;
            symbol.Family=(string)item.Attribute(W+"font");
            symbol.SmallCaps=false;
            int code=0;
            Require(new[]{"Symbol","Wingdings","Wingdings 2","Wingdings 3","Webdings"}
                .Contains(symbol.Family,StringComparer.OrdinalIgnoreCase) &&
                Int32.TryParse((string)item.Attribute(W+"char"),NumberStyles.AllowHexSpecifier,
                    CultureInfo.InvariantCulture,out code) && code>=0xf020 && code<=0xf0ff);
            yield return Tuple.Create(((char)code).ToString(),symbol);
        }
        if (text.Length>0) yield return Tuple.Create(text.ToString(),style);
    }

    private void AppendLabelWords(List<LabelWord> words,string value,LabelStyle style,
        Dictionary<Tuple<string,float,FontStyle>,Font> fonts,Graphics surface,StringFormat format)
    {
        characters+=value.Length;
        Require(characters<=4096 && value.All(c=>c=='\t' || !Char.IsControl(c)));
        foreach (Match token in Regex.Matches(value,"[\t\u00ad]| +|[^\t\u00ad ]+"))
        {
            var space=token.Value[0]==' ';
            var tab=token.Value=="\t";
            var marker=token.Value=="\u00ad";
            var last=words.Count==0 ? null : words[words.Count-1];
            if (last==null || last.HardBreak || last.Space!=space || tab || last.Tab)
            {
                last=new LabelWord { Space=space, Tab=tab };
                words.Add(last);
            }
            var valueToMeasure=tab ? "." : marker ? "-" : token.Value;
            var pieces=style.SmallCaps ? Regex.Matches(valueToMeasure,@"\p{Ll}+|[^\p{Ll}]+")
                .Cast<Match>().Select(piece=>piece.Value) : new[]{valueToMeasure};
            foreach(var piece in pieces)
            {
                var small=style.SmallCaps && Char.IsLower(piece,0);
                var size=style.Size*(small ? .8f : 1f)*(style.Script==0 ? 1f : .65f);
                var key=Tuple.Create(style.Family,size,style.FontFlags);
                Font font;
                if (!fonts.TryGetValue(key,out font))
                {
                    font=new Font(style.Family,key.Item2,style.FontFlags,GraphicsUnit.Pixel);
                    fonts.Add(key,font);
                    Require(String.Equals(font.FontFamily.Name,style.Family,StringComparison.OrdinalIgnoreCase));
                }
                var visible=small ? piece.ToUpperInvariant() : piece;
                var runWidth=TextWidth(surface,font,format,visible,style.Gap,style.WidthScale);
                var rise=style.Script>0 ? style.Size/3 : style.Script<0 ? -style.Size/5 : 0;
                last.Runs.Add(new LabelRun { Text=visible, Font=font, Color=style.Color, Gap=style.Gap, Width=runWidth,
                    WidthScale=style.WidthScale, Discretionary=marker, Rise=rise });
                if (!marker) last.Width+=runWidth;
            }
        }
    }

    private static float AddLabelLine(List<LabelLine> lines,LabelLine line,LabelStyle style,float y,bool last)
    {
        while (line.Words.Count>0 && (line.Words[line.Words.Count-1].Space || line.Words[line.Words.Count-1].Tab))
        {
            line.Width-=line.Words[line.Words.Count-1].Width;
            line.Words.RemoveAt(line.Words.Count-1);
        }
        if (line.Height==0) line.Height=style.Size;
        line.Last=last;
        line.Offset=y;
        lines.Add(line);
        var height=Math.Max(line.Height*1.15f,line.Height+line.Depth);
        if (style.LineRule=="exact") height=style.LineSpacing/20;
        else if (style.LineRule=="atLeast") height=Math.Max(height,style.LineSpacing/20);
        else height*=style.LineSpacing/240;
        Require(height>0 && height<=1200);
        return y+height;
    }

    private static void DrawRun(Graphics surface,StringFormat format,LabelRun run,Brush brush,float x,float y)
    {
        GraphicsState state=null;
        try
        {
            if (run.WidthScale!=1f)
            {
                state=surface.Save();
                surface.TranslateTransform(x,y);
                surface.ScaleTransform(run.WidthScale,1f);
                x=0; y=0;
            }
            if (run.Gap==0) surface.DrawString(run.Text,run.Font,brush,new PointF(x,y),format);
            else foreach (var glyph in TextElements(run.Text))
            {
                surface.DrawString(glyph,run.Font,brush,new PointF(x,y),format);
                x+=TextWidth(surface,run.Font,format,glyph,0)+run.Gap/run.WidthScale;
            }
        }
        finally { if (state!=null) surface.Restore(state); }
    }

    private static float TextWidth(Graphics graphic, Font font, StringFormat format, string value, float spacing,
        float widthScale=1f)
    {
        if (value.Length==0) return 0;
        if (spacing==0) return graphic.MeasureString(value,font,Int32.MaxValue,format).Width*widthScale;
        var elements=TextElements(value).ToArray();
        return elements.Sum(s=>graphic.MeasureString(s,font,Int32.MaxValue,format).Width)*widthScale+
            (elements.Length-1)*spacing;
    }

    private static IEnumerable<string> TextElements(string value)
    {
        var iterator=StringInfo.GetTextElementEnumerator(value);
        while (iterator.MoveNext()) yield return iterator.GetTextElement();
    }
}
