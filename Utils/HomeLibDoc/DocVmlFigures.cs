// Copyright (c) 2026 MyHomeLib contributors. MIT license; see ../../LICENSE.
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Globalization;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text.RegularExpressions;
using System.Xml;
using System.Xml.Linq;
using DocSharp.Binary.DocFileFormat;
using DocSharp.Binary.OfficeDrawing;
using DocSharp.Binary.StructuredStorage.Reader;

// DocSharp places each part of some Word 97–2003 figures in a different
// paragraph. Keep a supported figure together when the document is reflowed.
internal static class DocVmlFigures
{
    private static readonly XNamespace W = "http://schemas.openxmlformats.org/wordprocessingml/2006/main";
    private static readonly XNamespace WP = "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing";
    private static readonly XNamespace R = "http://schemas.openxmlformats.org/officeDocument/2006/relationships";
    private static readonly XNamespace V = "urn:schemas-microsoft-com:vml";
    private static readonly XNamespace O = "urn:schemas-microsoft-com:office:office";
    private static readonly XNamespace Rel = "http://schemas.openxmlformats.org/package/2006/relationships";
    private static readonly XNamespace Types = "http://schemas.openxmlformats.org/package/2006/content-types";
    private static readonly Regex PointSize = new Regex(@"^[+-]?(?:\d{1,4}(?:\.\d{1,4})?|\.\d{1,4})pt$");
    private static readonly Regex LineOrder = new Regex(@"^z-index:[0-9]{1,8};$");
    private static readonly Regex MarginLineOrder = new Regex(@"^mso-position-horizontal-relative:margin;z-index:[0-9]{1,8};$");
    private static readonly Regex PageConnectorStyle = new Regex(
        @"^position:absolute;margin-left:([^;]{1,24});margin-top:([^;]{1,24});width:([^;]{1,24});height:([^;]{1,24});" +
        @"z-index:-1;mso-position-horizontal-relative:page;mso-position-vertical-relative:page;z-index:[0-9]{1,8};$");
    private static readonly Regex PathToken = new Regex(@"[mlcxe]|-?\d{1,6}");
    private static readonly Regex Separators = new Regex(@"^[\s,]*$");
    private const int Scale = 3; // 216 dpi, in points
    private const int MaxFigureBytes = 8 * 1024 * 1024;
    private const int MaxFigures = 256;
    private const int MaxParagraphs = 24;
    private const float BodyLineHeight = 14; // Word's single-spaced 12 pt Arial

    private sealed class Shape : IDisposable
    {
        internal GraphicsPath Path = new GraphicsPath();
        internal PointF Start;
        internal PointF End;
        internal int Layer;
        internal bool Line;
        internal bool Arrow;
        internal bool OpenArrowStart, OpenArrowEnd;
        internal float Stroke = 1;
        internal Color Fill = Color.Transparent;
        internal string Label;
        internal Font LabelFont;
        internal RectangleF LabelBounds;
        internal Bitmap Picture;
        internal RectangleF PictureBounds;
        internal bool Caption;
        internal void Draw(Graphics g)
        {
            if (Picture!=null)
            {
                g.DrawImage(Picture,PictureBounds);
                return;
            }
            if (!Caption)
            {
                if (Fill.A>0)
                    using (var brush=new SolidBrush(Fill)) g.FillPath(brush,Path);
                using (var pen=new Pen(Color.Black,Stroke)) g.DrawPath(pen,Path);
                if (OpenArrowStart) DrawOpenArrow(g,End,Start);
                if (OpenArrowEnd) DrawOpenArrow(g,Start,End);
            }
            if (LabelFont!=null)
                using (var format=(StringFormat)StringFormat.GenericTypographic.Clone())
                {
                    format.FormatFlags |= StringFormatFlags.NoWrap | StringFormatFlags.MeasureTrailingSpaces;
                    g.DrawString(Label,LabelFont,Brushes.Black,LabelBounds,format);
                }
            if (!Arrow) return;
            var dx = End.X - Start.X;
            var dy = End.Y - Start.Y;
            var length = (float)Math.Sqrt(dx * dx + dy * dy);
            if (length < 1) return;
            var tipLength = Math.Min(6, length);
            dx /= length;
            dy /= length;
            var x = End.X - dx * tipLength;
            var y = End.Y - dy * tipLength;
            g.FillPolygon(Brushes.Black, new[] { End, new PointF(x - dy * 3, y + dx * 3),
                new PointF(x + dy * 3, y - dx * 3) });
        }
        private void DrawOpenArrow(Graphics surface, PointF from, PointF to)
        {
            var dx=to.X-from.X;
            var dy=to.Y-from.Y;
            var length=(float)Math.Sqrt(dx*dx+dy*dy);
            if (length<1) return;
            dx/=length;
            dy/=length;
            var depth=Math.Min(length,Stroke*9);
            var width=depth*.55f;
            var baseX=to.X-dx*depth;
            var baseY=to.Y-dy*depth;
            using (var pen=new Pen(Color.Black,Stroke*1.5f))
                surface.DrawLines(pen,new[]{new PointF(baseX-dy*width,baseY+dx*width),to,
                    new PointF(baseX+dy*width,baseY-dx*width)});
        }
        public void Dispose()
        {
            Path.Dispose();
            if (LabelFont!=null) LabelFont.Dispose();
            if (Picture!=null) Picture.Dispose();
        }
    }

    private static XDocument Read(ZipArchive archive, string name)
    {
        var entry = archive.GetEntry(name);
        if (entry == null || entry.Length > HomeLibDoc.MaximumBytes) return null;
        using (var input = entry.Open())
        using (var reader = ReadXml(input))
            return XDocument.Load(reader, LoadOptions.PreserveWhitespace);
    }

    private static XmlReader ReadXml(Stream input)
    {
        return XmlReader.Create(input, new XmlReaderSettings {
            DtdProcessing = DtdProcessing.Prohibit, XmlResolver = null,
            MaxCharactersInDocument = HomeLibDoc.MaximumBytes });
    }

    private static void InspectDrawings(ZipArchiveEntry entry, out bool freeform, out bool emptyPictures,
        out bool paragraphRules, out bool marginRules, out bool compoundFigures, out bool groupedLines)
    {
        freeform = false;
        emptyPictures = false;
        paragraphRules = false;
        marginRules = false;
        compoundFigures = false;
        groupedLines = false;
        if (entry == null || entry.Length > HomeLibDoc.MaximumBytes) return;
        using (var input = entry.Open())
        using (var reader = ReadXml(input))
            while (reader.Read())
            {
                if (reader.NodeType != XmlNodeType.Element) continue;
                if (reader.LocalName == "shape" && reader.NamespaceURI == V.NamespaceName &&
                    reader.GetAttribute("path") != null) freeform = true;
                if (reader.LocalName == "pict" && reader.NamespaceURI == W.NamespaceName &&
                    reader.IsEmptyElement) emptyPictures = true;
                if (reader.NamespaceURI == V.NamespaceName && (reader.LocalName == "rect" || reader.LocalName == "oval"))
                    compoundFigures = true;
                if (reader.NamespaceURI == V.NamespaceName && reader.LocalName == "group")
                    groupedLines = true;
                if (reader.LocalName == "line" && reader.NamespaceURI == V.NamespaceName &&
                    reader.GetAttribute("type") == "#_x0000_t20")
                {
                    var style = reader.GetAttribute("style") ?? "";
                    paragraphRules |= LineOrder.IsMatch(style);
                    marginRules |= MarginLineOrder.IsMatch(style);
                }
                if (reader.LocalName == "shape" && reader.NamespaceURI == V.NamespaceName &&
                    reader.GetAttribute("type") == "#_x0000_t32")
                    marginRules |= PageConnectorStyle.IsMatch(reader.GetAttribute("style") ?? "");
                if (freeform && emptyPictures && paragraphRules && marginRules && compoundFigures && groupedLines) break;
            }
    }

    private sealed class GroupDrawing
    {
        public int GroupId;
        public ChildAnchor Anchor;
        public int Rotation;
        public string ArcPath, ArcSize;
    }

    private static bool TryShapeId(XElement node, out int id)
    {
        id=0;
        const string prefix="_x0000_s";
        var value=node==null ? null : (string)node.Attribute("id");
        return value!=null && value.StartsWith(prefix,StringComparison.Ordinal) &&
            Int32.TryParse(value.Substring(prefix.Length),NumberStyles.None,CultureInfo.InvariantCulture,out id);
    }

    private static bool RepairGroupDrawingGeometry(XElement body, WordDocument original)
    {
        var candidates=body.Descendants().Where(n=>n.Parent!=null && n.Parent.Name==V+"group" &&
            (n.Name==V+"line" && (string)n.Attribute("type")=="#_x0000_t20" && n.Attribute("from")!=null && n.Attribute("to")!=null ||
             n.Name==V+"shape" && (string)n.Attribute("type")=="#_x0000_t19" && n.Attribute("path")==null)).ToArray();
        var drawings=original.OfficeArtContent==null ? null : original.OfficeArtContent.Drawings;
        if (candidates.Length==0 || drawings==null) return false;
        var originals=new Dictionary<int,GroupDrawing>();
        var ambiguous=new HashSet<int>();
        foreach (var drawing in drawings)
            FindGroupDrawings(drawing.container,0,0,originals,ambiguous);

        var changed=false;
        foreach (var drawing in candidates)
        {
            int id, groupId;
            GroupDrawing source;
            if (!TryShapeId(drawing,out id) || !TryShapeId(drawing.Parent,out groupId) || ambiguous.Contains(id) ||
                !originals.TryGetValue(id,out source) || groupId!=source.GroupId) continue;
            if (drawing.Name==V+"shape")
            {
                if (source.ArcPath==null) continue;
                drawing.SetAttributeValue("coordsize",source.ArcSize);
                drawing.SetAttributeValue("path",source.ArcPath);
                changed=true;
                continue;
            }
            if (source.ArcPath!=null) continue;
            var anchor=source.Anchor;
            var from=String.Format(CultureInfo.InvariantCulture,"{0},{1}",anchor.Left,anchor.Top);
            var to=String.Format(CultureInfo.InvariantCulture,"{0},{1}",anchor.Right,anchor.Bottom);
            var styles=((string)drawing.Attribute("style")??"").Split(new[]{';'},StringSplitOptions.RemoveEmptyEntries)
                .Where(part=>!part.StartsWith("rotation:",StringComparison.OrdinalIgnoreCase)).ToList();
            if (source.Rotation!=0)
                styles.Add("rotation:"+((decimal)source.Rotation/65536).ToString(CultureInfo.InvariantCulture));
            var style=styles.Count==0 ? null : String.Join(";",styles)+";";
            if ((string)drawing.Attribute("from")==from && (string)drawing.Attribute("to")==to &&
                (string)drawing.Attribute("style")==style) continue;
            // The binary child anchor is in the parent's coordinate space.
            // DocSharp's line attributes can instead reuse the page anchor of
            // the entire group. The rotation option is signed 16.16 degrees.
            drawing.SetAttributeValue("from",from);
            drawing.SetAttributeValue("to",to);
            drawing.SetAttributeValue("style",style);
            changed=true;
        }
        return changed;
    }

    private static void FindGroupDrawings(Record record, int groupId, int depth, Dictionary<int,GroupDrawing> originals,
        HashSet<int> ambiguous)
    {
        var container=record as RegularContainer;
        if (container==null || depth>32) return;
        if (container is GroupContainer && container.Children.Count>0)
        {
            var groupShape=container.Children[0] as ShapeContainer;
            var group=groupShape==null ? null : groupShape.Children.OfType<DocSharp.Binary.OfficeDrawing.Shape>().FirstOrDefault();
            groupId=group==null ? 0 : group.spid;
        }
        var shape=container as ShapeContainer;
        if (shape!=null && groupId!=0)
        {
            var shapeInfo=shape.Children.OfType<DocSharp.Binary.OfficeDrawing.Shape>().FirstOrDefault();
            var anchor=shape.Children.OfType<ChildAnchor>().FirstOrDefault();
            if (shapeInfo!=null && (shapeInfo.Instance==19 || shapeInfo.Instance==20) &&
                shapeInfo.fChild && !shapeInfo.fDeleted && anchor!=null &&
                anchor.Right>=anchor.Left && anchor.Bottom>=anchor.Top)
            {
                var options=shape.ExtractOptions().ToArray();
                var drawing=new GroupDrawing {
                    GroupId=groupId,
                    Anchor=anchor,
                    Rotation=unchecked((int)options.FirstOrDefault(option=>option.pid==ShapeOptions.PropertyId.rotation).op)
                };
                if (shapeInfo.Instance==19) ReadGroupArc(options,drawing);
                if (originals.ContainsKey(shapeInfo.spid)) ambiguous.Add(shapeInfo.spid);
                else if (shapeInfo.Instance==20 || drawing.ArcPath!=null) originals.Add(shapeInfo.spid,drawing);
            }
        }
        foreach (var child in container.Children) FindGroupDrawings(child,groupId,depth+1,originals,ambiguous);
    }

    private static void ReadGroupArc(ShapeOptions.OptionEntry[] options,GroupDrawing drawing)
    {
        var vertices=options.FirstOrDefault(o=>o.pid==ShapeOptions.PropertyId.pVertices).opComplex;
        if (vertices==null || vertices.Length!=78 || BitConverter.ToUInt16(vertices,0)!=9 ||
            BitConverter.ToUInt16(vertices,2)<9 || BitConverter.ToUInt16(vertices,4)!=8 ||
            options.Any(o=>o.pid==ShapeOptions.PropertyId.pSegmentInfo) || drawing.Rotation!=0) return;
        var right=options.Where(o=>o.pid==ShapeOptions.PropertyId.geoRight).Select(o=>o.op).DefaultIfEmpty(21600u).First();
        var bottom=options.Where(o=>o.pid==ShapeOptions.PropertyId.geoBottom).Select(o=>o.op).DefaultIfEmpty(21600u).First();
        if (right==0 || right>1000000 || bottom==0 || bottom>1000000 ||
            options.Any(o=>(o.pid==ShapeOptions.PropertyId.geoLeft || o.pid==ShapeOptions.PropertyId.geoTop) && o.op!=0)) return;
        var coordinates=Enumerable.Range(0,18).Select(i=>BitConverter.ToInt32(vertices,6+4*i)).ToArray();
        if (coordinates.Any(i=>i < -1000000 || i>1000000) ||
            !coordinates.Take(8).SequenceEqual(coordinates.Skip(8).Take(8))) return;
        var arc=String.Join(",",coordinates.Take(8).Select(i=>i.ToString(CultureInfo.InvariantCulture)));
        var center=String.Join(",",coordinates.Skip(16).Select(i=>i.ToString(CultureInfo.InvariantCulture)));
        // Arc preset geometry strokes the open curve and fills the sector separately.
        drawing.ArcPath="wr"+arc+"nfewr"+arc+"l"+center+"nsxe";
        drawing.ArcSize=String.Format(CultureInfo.InvariantCulture,"{0},{1}",right,bottom);
    }

    private static void Save(ZipArchive archive, string name, XDocument doc)
    {
        using (var output = archive.CreateEntry(name).Open()) doc.Save(output, SaveOptions.DisableFormatting);
    }

    private static float? Points(string value)
    {
        float result;
        return value != null && PointSize.IsMatch(value) &&
            Single.TryParse(value.Substring(0, value.Length - 2), NumberStyles.Float, CultureInfo.InvariantCulture, out result)
            ? (float?)result : null;
    }

    private static PointF? LinePoint(string value)
    {
        var fields = (value ?? "").Split(',');
        if (fields.Length != 2) return null;
        var x = Points(fields[0]);
        var y = Points(fields[1]);
        return x.HasValue && y.HasValue ? (PointF?)new PointF(x.Value, y.Value) : null;
    }

    private static bool ReadPath(Shape shape, string commands, RectangleF frame, int width, int height)
    {
        if (String.IsNullOrEmpty(commands) || commands.Length > 65536) return false;
        var tokens = PathToken.Matches(commands);
        var index = 0;
        foreach (Match token in tokens)
        {
            if (!Separators.IsMatch(commands.Substring(index, token.Index - index))) return false;
            index = token.Index + token.Length;
        }
        if (!Separators.IsMatch(commands.Substring(index)) || tokens.Count < 7) return false;
        var command = "";
        var position = new PointF();
        var newFigure = true;
        for (var i = 0; i < tokens.Count;)
        {
            var token = tokens[i].Value;
            if (token == "e") return i == tokens.Count - 1 && shape.Path.PointCount > 0;
            if (token == "x")
            {
                if (newFigure) return false;
                shape.Path.CloseFigure();
                command = "";
                newFigure = true;
                i++;
                continue;
            }
            if (token == "m" || token == "l" || token == "c") { command = token; i++; }
            var pointCount = command == "c" ? 3 : 1;
            if (command == "" || i + 2 * pointCount > tokens.Count) return false;
            var points = new PointF[pointCount];
            for (var p = 0; p < pointCount; p++)
            {
                int x, y;
                if (!Int32.TryParse(tokens[i++].Value, out x) || !Int32.TryParse(tokens[i++].Value, out y)) return false;
                // Control points can extend past the freeform rectangle.
                if (x < -width || x > 2L * width || y < -height || y > 2L * height) return false;
                points[p] = new PointF(frame.X + x * frame.Width / width, frame.Y + y * frame.Height / height);
            }
            if (command == "m")
            {
                shape.Path.StartFigure();
                newFigure = false;
                command = "";
            }
            else if (newFigure) return false;
            else if (command == "l") shape.Path.AddLine(position, points[0]);
            else shape.Path.AddBezier(position, points[0], points[1], points[2]);
            position = points[pointCount - 1];
        }
        return false;
    }

    private static bool ReadShape(XElement node, float top, Shape shape)
    {
        if ((string)node.Attribute("filled") != "f" ||
            node.Attributes().Any(a => !a.IsNamespaceDeclaration &&
                !new[] { "id", "type", "filled", "style", "path", "coordsize", "from", "to" }.Contains(a.Name.ToString())))
            return false;
        var style = new Dictionary<string, string>();
        var flipX = false;
        var flipY = false;
        foreach (var item in ((string)node.Attribute("style") ?? "").Split(';'))
        {
            if (item.Length == 0) continue;
            var pair = item.Split(':');
            if (pair.Length != 2) return false;
            if (pair[0] == "flip" && pair[1] == "x") flipX = true;
            else if (pair[0] == "flip" && pair[1] == "y") flipY = true;
            else if (style.ContainsKey(pair[0])) return false;
            else style.Add(pair[0], pair[1]);
        }
        string layer;
        if (style.TryGetValue("z-index", out layer) && !Int32.TryParse(layer, out shape.Layer)) return false;
        if (node.Name == V + "line")
        {
            var from = LinePoint((string)node.Attribute("from"));
            var to = LinePoint((string)node.Attribute("to"));
            var strokes = node.Elements().ToArray();
            var type = (string)node.Attribute("type");
            if (!from.HasValue || !to.HasValue || (type != null && type != "#_x0000_t20") ||
                node.Attribute("path") != null || node.Attribute("coordsize") != null ||
                style.Keys.Any(key => key != "z-index") ||
                strokes.Length > 1 || (strokes.Length == 1 && (strokes[0].Name != V + "stroke" ||
                strokes[0].HasElements || strokes[0].Attributes().Count() != 1 ||
                (string)strokes[0].Attribute("endarrow") != "block"))) return false;
            shape.Line = true;
            shape.Arrow = strokes.Length == 1;
            shape.Start = new PointF(flipX ? to.Value.X : from.Value.X, top + (flipY ? to.Value.Y : from.Value.Y));
            shape.End = new PointF(flipX ? from.Value.X : to.Value.X, top + (flipY ? from.Value.Y : to.Value.Y));
            shape.Path.AddLine(shape.Start, shape.End);
            return true;
        }
        if (node.Name != V + "shape" || node.HasElements || flipX || flipY ||
            node.Attribute("type") != null || node.Attribute("from") != null || node.Attribute("to") != null) return false;
        foreach (var item in style)
            switch (item.Key)
            {
                case "position": case "mso-position-horizontal": case "mso-position-vertical":
                    if (item.Value != "absolute") return false;
                    break;
                case "mso-position-horizontal-relative": case "mso-position-vertical-relative":
                    if (item.Value != "text") return false;
                    break;
                case "margin-left": case "margin-top": case "width": case "height": case "z-index": break;
                default: return false;
            }
        if (!style.ContainsKey("position")) return false;
        var dimensions = new[] { "margin-left", "margin-top", "width", "height" };
        var frame = dimensions.Select(key => style.ContainsKey(key) ? Points(style[key]) : null).ToArray();
        var size = ((string)node.Attribute("coordsize") ?? "").Split(',');
        int width, height;
        if (frame.Any(value => !value.HasValue) || frame[2] <= 0 || frame[3] <= 0 ||
            size.Length != 2 || !Int32.TryParse(size[0], out width) || !Int32.TryParse(size[1], out height) ||
            width <= 0 || height <= 0 || width > 1000000 || height > 1000000) return false;
        return ReadPath(shape, (string)node.Attribute("path"),
            new RectangleF(frame[0].Value, top + frame[1].Value, frame[2].Value, frame[3].Value), width, height);
    }

    private static bool ReadPlotParagraph(XElement paragraph, List<XElement> drawings, out string text)
    {
        text = "";
        if (paragraph.Name != W + "p") return false;
        foreach (var element in paragraph.Elements())
        {
            if (element.Name == W + "pPr")
            {
                if (element.Elements().Any(x =>
                    !(x.Name == W + "pStyle" && (string)x.Attribute(W + "val") == "Normal") && x.Name != W + "rPr" &&
                    (x.Name != W + "ind" || x.Attributes().Any(a => a.Name != W + "firstLine")))) return false;
                continue;
            }
            if (element.Name != W + "r") return false;
            foreach (var item in element.Elements())
            {
                if (item.Name == W + "t" || item.Name == W + "instrText")
                {
                    if (item.Value.Length > 180 - text.Length) return false;
                    text += item.Value;
                }
                else if (item.Name == W + "pict")
                {
                    var contents = item.Elements().ToArray();
                    if (contents.Length == 0 || contents.Any(x => x.Name != V + "line" && x.Name != V + "shape"))
                        return false;
                    drawings.AddRange(contents);
                }
                else if (item.Name != W + "rPr" && item.Name != W + "tab") return false;
            }
        }
        text = text.Trim();
        return text.Length == 0 || (text.Length == 1 && Char.IsLetter(text[0])) ||
            (text.Length > 1 && text.All(c => Char.IsWhiteSpace(c) || c == '-' || c == '_'));
    }

    // The two long arrowed axes and one freeform identify a plot. Everything
    // else is left intact, including unsupported VML and ordinary paragraphs.
    private static byte[] Plot(List<Shape> shapes, List<string> text, ref int totalBytes, out Size size)
    {
        size = Size.Empty;
        var vertical = shapes.Where(s => s.Line && s.Arrow && s.Start.X == s.End.X &&
            s.Start.Y - s.End.Y >= 32).OrderByDescending(s => s.Start.Y - s.End.Y).FirstOrDefault();
        var horizontal = shapes.Where(s => s.Line && s.Arrow && s.Start.Y == s.End.Y &&
            s.End.X - s.Start.X >= 64).OrderByDescending(s => s.End.X - s.Start.X).FirstOrDefault();
        var labels = text.Where(s => s.Length == 1 && Char.IsLetter(s[0])).ToArray();
        var rules = text.Select((s, i) => new { Text = s, Index = i }).Where(t => t.Text.Length > 1).ToArray();
        if (vertical == null || horizontal == null || labels.Length != 2 || rules.Length > 1 ||
            shapes.Count(s => !s.Line) != 1 || Math.Abs(vertical.Start.X - horizontal.Start.X) > 8 ||
            vertical.End.Y >= horizontal.End.Y || horizontal.End.Y - vertical.End.Y > 288) return null;
        var bounds = shapes.Select(s => s.Path.GetBounds()).Aggregate(RectangleF.Union);
        if (bounds.Width < 64 || bounds.Width > 720 || bounds.Height < 32 || bounds.Height > 288) return null;
        bounds.Inflate(7, 9);
        var width = (int)Math.Ceiling(bounds.Width * Scale);
        var height = (int)Math.Ceiling(bounds.Height * Scale);
        using (var image = new Bitmap(width, height, PixelFormat.Format32bppPArgb))
        using (var g = Graphics.FromImage(image))
        using (var headingFont = new Font("Arial", 14, FontStyle.Bold | FontStyle.Italic, GraphicsUnit.Pixel))
        using (var labelFont = new Font("Arial", 14, FontStyle.Bold, GraphicsUnit.Pixel))
        using (var rulePen = new Pen(Color.Black, 0.8f))
        using (var stream = new MemoryStream())
        {
            g.Clear(Color.White);
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.ScaleTransform(Scale, Scale);
            g.TranslateTransform(-bounds.Left, -bounds.Top);
            foreach (var shape in shapes.OrderBy(s => s.Layer)) shape.Draw(g);
            g.DrawString(labels[0], headingFont, Brushes.Black, vertical.End.X + 8, vertical.End.Y - 8);
            g.DrawString(labels[1], labelFont, Brushes.Black, horizontal.End.X - 17, horizontal.End.Y - 21);
            foreach (var rule in rules)
            {
                var y = shapes.Where(s => s.Line && !s.Arrow && s.Start.Y == s.End.Y &&
                    Math.Min(s.Start.X, s.End.X) <= vertical.End.X && Math.Max(s.Start.X, s.End.X) >= vertical.End.X)
                    .Select(s => s.Start.Y).OrderBy(p => Math.Abs(p - (rule.Index + 0.6f) * BodyLineHeight)).FirstOrDefault();
                if (y <= vertical.End.Y || y >= horizontal.End.Y) return null;
                var underlines = rule.Text.Count(c => c == '_');
                var hyphens = rule.Text.Count(c => c == '-');
                var left = vertical.End.X + 10;
                var right = Math.Min(horizontal.End.X - 4, left + 10 * underlines + 7.33f * hyphens);
                rulePen.DashPattern = underlines > 0 ? new[] { 8.3f, 4.2f } : new[] { 5f, 4.2f };
                g.DrawLine(rulePen, left, y, right, y);
            }
            image.Save(stream, ImageFormat.Png);
            if (stream.Length + totalBytes > MaxFigureBytes) return null;
            totalBytes += (int)stream.Length;
            size = image.Size;
            return stream.ToArray();
        }
    }

    private static void RestoreLegendArrow(XElement paragraph)
    {
        if (paragraph == null || paragraph.Name != W + "p") return;
        var picts = paragraph.Elements(W + "r").SelectMany(n => n.Elements(W + "pict")).ToArray();
        var nodes = paragraph.Elements(W + "r").SelectMany(n => n.Elements()).ToArray();
        var tabs = nodes.Where(n => n.Name == W + "tab").ToArray();
        if (picts.Length != 1 || picts[0].Elements().Count() != 1 || tabs.Length != 1 ||
            nodes.Any(n => n.Name != W + "rPr" && n.Name != W + "t" && n.Name != W + "instrText" &&
                           n.Name != W + "tab" && n.Name != W + "pict")) return;
        using (var shape = new Shape())
        {
            if (!ReadShape(picts[0].Elements().Single(), 0, shape) || !shape.Line || !shape.Arrow ||
                shape.Start.X != shape.End.X || shape.Start.Y - shape.End.Y < 2 || shape.Start.Y - shape.End.Y > 12) return;
            var pos = Array.IndexOf(nodes, tabs[0]);
            var before = String.Concat(nodes.Take(pos).Where(n => n.Name == W + "t" || n.Name == W + "instrText").Select(n => n.Value)).TrimEnd();
            var after = String.Concat(nodes.Skip(pos + 1).Where(n => n.Name == W + "t" || n.Name == W + "instrText").Select(n => n.Value)).TrimStart();
            if (!before.EndsWith(":", StringComparison.Ordinal) ||
                !(after.StartsWith("\u2013", StringComparison.Ordinal) || after.StartsWith("\u2014", StringComparison.Ordinal))) return;
            tabs[0].ReplaceWith(new XElement(W + "t", new XAttribute(XNamespace.Xml + "space", "preserve"), " \u2191"));
            picts[0].Remove();
        }
    }

    private static XElement ImageDrawing(string id, int number, int width, int height, string alternative)
    {
        XNamespace wp = "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing";
        XNamespace a = "http://schemas.openxmlformats.org/drawingml/2006/main";
        XNamespace pic = "http://schemas.openxmlformats.org/drawingml/2006/picture";
        var picture = new XElement(pic + "pic",
            new XElement(pic + "nvPicPr", new XElement(pic + "cNvPr", new XAttribute("id", 0), new XAttribute("name", id)),
                new XElement(pic + "cNvPicPr")),
            new XElement(pic + "blipFill", new XElement(a + "blip", new XAttribute(R + "embed", id)),
                new XElement(a + "stretch", new XElement(a + "fillRect"))),
            new XElement(pic + "spPr",
                new XElement(a + "xfrm", new XElement(a + "off", new XAttribute("x", 0), new XAttribute("y", 0)),
                    new XElement(a + "ext", new XAttribute("cx", width), new XAttribute("cy", height))),
                new XElement(a + "prstGeom", new XAttribute("prst", "rect"), new XElement(a + "avLst"))));
        var inline = new XElement(wp + "inline",
            new XElement(wp + "extent", new XAttribute("cx", width), new XAttribute("cy", height)),
            new XElement(wp + "docPr", new XAttribute("id", number), new XAttribute("name", id), new XAttribute("descr", alternative)),
            new XElement(a + "graphic", new XElement(a + "graphicData", new XAttribute("uri", pic.NamespaceName), picture)));
        return new XElement(W + "drawing", inline);
    }

    private static XElement ImageParagraph(string id, int number, Size size, string alternative)
    {
        var drawing = ImageDrawing(id, number, size.Width * 12700 / Scale,
            size.Height * 12700 / Scale, alternative);
        return new XElement(W + "p", new XElement(W + "r", drawing));
    }

    private sealed class HorizontalRule
    {
        internal int Height, Width, Percentage;
        internal Color Color;
        internal bool Solid;
    }

    private static bool IsEmptyPicture(XElement picture)
    {
        return !picture.Nodes().Any() && picture.Attributes().All(attribute => attribute.IsNamespaceDeclaration);
    }

    private static PictureDescriptor ReadInlinePicture(WordDocument source, int cp)
    {
        int fc;
        if (!source.PieceTable.FileCharacterPositions.TryGetValue(cp, out fc) || fc == Int32.MaxValue)
            return null;
        var properties = source.GetCharacterPropertyExceptions(fc, fc + 1).FirstOrDefault();
        if (properties == null) return null;
        var offset = PictureDescriptor.GetFcPic(properties);
        return offset >= 0 && offset <= source.DataStream.Length - 68
            ? new PictureDescriptor(properties, source.DataStream)
            : null;
    }

    private static bool IsPseudoInline(IEnumerable<ShapeOptions.OptionEntry> options)
    {
        var flags = options.FirstOrDefault(option => option.pid == ShapeOptions.PropertyId.diagramBooleans).op;
        const uint PseudoInlineAndUse = 0x00010001;
        return (flags & PseudoInlineAndUse) == PseudoInlineAndUse;
    }

    private static byte[] ReadStoredPicture(WordDocument source, BlipStoreEntry entry)
    {
        if (entry == null) return null;
        var png = entry.btWin32 == BlipStoreEntry.BlipType.msoblipPNG;
        var jpeg = entry.btWin32 == BlipStoreEntry.BlipType.msoblipJPEG ||
            entry.btWin32 == BlipStoreEntry.BlipType.msoblipCMYKJPEG;
        if (!png && !jpeg) return null;
        var signature = png ? new byte[] { 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A } :
            new byte[] { 0xFF, 0xD8, 0xFF };
        if (entry.Blip != null)
        {
            var bitmap = entry.Blip as BitmapBlip;
            var pixels = bitmap == null ? null : bitmap.m_pvBits;
            return pixels != null && pixels.Take(signature.Length).SequenceEqual(signature) ? pixels : null;
        }

        // The delayed drawing-store reference addresses WordDocument.
        var stream = source.WordDocumentStream;
        var offset = entry.foDelay;
        if (offset > stream.Length - 8) return null;
        var previous = stream.Position;
        try
        {
            stream.Position = offset;
            var reader = new VirtualStreamReader(stream);
            var options = reader.ReadUInt16();
            var type = reader.ReadUInt16();
            var size = reader.ReadUInt32();
            if ((options & 0xF) != 0 || size > stream.Length - stream.Position) return null;
            var instance = options >> 4;
            int header;
            if (png && type == 0xF01E && (instance == 0x6E0 || instance == 0x6E1))
                header = instance == 0x6E0 ? 17 : 33;
            else if (jpeg && (type == 0xF01D || type == 0xF02A) &&
                (instance == 0x46A || instance == 0x46B || instance == 0x6E2 || instance == 0x6E3))
                header = (instance & 1) == 0 ? 17 : 33;
            else return null;
            if (size <= header) return null;
            stream.Position += header;
            var bytes = reader.ReadBytes((int)size - header);
            return bytes.Length == size - header && bytes.Take(signature.Length).SequenceEqual(signature) ? bytes : null;
        }
        finally { stream.Position = previous; }
    }

    private static bool RemoveDuplicateInlinePictures(ZipArchive archive, XElement body,
        WordDocument source, XDocument relationships)
    {
        var anchors = source.OfficeDrawingPlex;
        var art = source.OfficeArtContent;
        var group = art == null ? null : art.DrawingGroupData;
        var store = group == null ? null : group.FirstChildWithType<BlipStoreContainer>() as BlipStoreContainer;
        if (store == null || anchors == null || anchors.Elements.Count == 0) return false;

        var expected = new Dictionary<string, int>();
        var lengths = new HashSet<int>();
        using (var digest = SHA256.Create())
        {
            var length = Math.Min(source.Text.Count, source.FIB.ccpText);
            for (var index = 0; index < anchors.Elements.Count; index++)
            {
                var position = anchors.CharacterPositions[index];
                if (position < 0 || position >= length - 1 || source.Text[position] != '\u0008' ||
                    source.Text[position + 1] != '\u0001') continue;
                var floating = art.GetShapeContainer(anchors.Elements[index].spid);
                if (floating == null) continue;
                var properties = floating.ExtractOptions();
                var pictureIndex = properties.FirstOrDefault(option => option.pid == ShapeOptions.PropertyId.Pib).op;
                if (pictureIndex == 0 || pictureIndex > store.Children.Count || !IsPseudoInline(properties)) continue;
                var inline = ReadInlinePicture(source, position + 1);
                if (inline == null || inline.mfp.mm <= 98 || inline.BlipStoreEntry != null ||
                    inline.ShapeContainer == null) continue;
                var inlineProperties = inline.ShapeContainer.ExtractOptions();
                if (!IsPseudoInline(inlineProperties) || inlineProperties.Any(option =>
                    option.pid == ShapeOptions.PropertyId.Pib || option.pid == ShapeOptions.PropertyId.pibName ||
                    option.pid == ShapeOptions.PropertyId.pibFlags)) continue;
                var bitmap = ReadStoredPicture(source, store.Children[(int)pictureIndex - 1] as BlipStoreEntry);
                if (bitmap == null) continue;
                var key = Convert.ToBase64String(digest.ComputeHash(bitmap));
                expected[key] = expected.ContainsKey(key) ? expected[key] + 1 : 1;
                lengths.Add(bitmap.Length);
            }
            if (expected.Count == 0) return false;

            var targets = new Dictionary<string, string>();
            foreach (var relationship in relationships.Root.Elements(Rel + "Relationship"))
            {
                var id = (string)relationship.Attribute("Id");
                var name = ((string)relationship.Attribute("Target") ?? "").TrimStart('/');
                if (id == null || (string)relationship.Attribute("Type") != R.NamespaceName + "/image" ||
                    relationship.Attribute("TargetMode") != null) continue;
                if (name.StartsWith("media/", StringComparison.Ordinal)) name = "word/" + name;
                if (Regex.IsMatch(name, @"^word/media/[a-zA-Z0-9_.-]+\.(?:png|jpe?g)$")) targets[id] = name;
            }
            var matches = new Dictionary<string, List<XElement>>();
            var checkedMembers = new Dictionary<string, string>();
            var drawingBitmap = XName.Get("blip", "http://schemas.openxmlformats.org/drawingml/2006/main");
            foreach (var reference in body.Descendants().Where(node => node.Name == V + "imagedata" || node.Name == drawingBitmap))
            {
                var id = (string)reference.Attribute(R + (reference.Name == drawingBitmap ? "embed" : "id"));
                string name, key;
                if (id == null || !targets.TryGetValue(id, out name)) continue;
                if (!checkedMembers.TryGetValue(name, out key))
                {
                    var image = archive.GetEntry(name);
                    if (image != null && image.Length <= Int32.MaxValue && lengths.Contains((int)image.Length))
                        using (var data = image.Open()) key = Convert.ToBase64String(digest.ComputeHash(data));
                    checkedMembers.Add(name, key);
                }
                if (key == null || !expected.ContainsKey(key)) continue;
                List<XElement> instances;
                if (!matches.TryGetValue(key, out instances)) matches[key] = instances = new List<XElement>();
                instances.Add(reference);
            }

            var changed = false;
            foreach (var pair in matches)
            {
                // Repeated image bytes alone cannot identify which occurrence owns a slot.
                if (expected[pair.Key] != 1 || pair.Value.Count != 1) continue;
                var picture = pair.Value[0].Ancestors(W + "pict").FirstOrDefault();
                if (picture == null || picture.Parent == null || picture.Parent.Name != W + "r" ||
                    picture.Parent.Parent == null || picture.Parent.Parent.Name != W + "p") continue;
                var nextRun = picture.Parent.ElementsAfterSelf().FirstOrDefault();
                var placeholder = nextRun == null || nextRun.Name != W + "r" ? null :
                    nextRun.Elements().FirstOrDefault(item => !IsBlankRunProperty(item));
                if (placeholder == null || placeholder.Name != W + "pict" || !IsEmptyPicture(placeholder) ||
                    picture.ElementsAfterSelf().Any(item => !IsBlankRunProperty(item))) continue;
                placeholder.Remove();
                changed = true;
            }
            return changed;
        }
    }

    private static bool IsBlankRunProperty(XElement item)
    {
        return item.Name == W + "rPr" || ((item.Name == W + "t" || item.Name == W + "instrText") &&
            !item.HasElements && String.IsNullOrWhiteSpace(item.Value));
    }

    private static HorizontalRule ReadSolidInlineRule(PictureDescriptor picture,
        IEnumerable<ShapeOptions.OptionEntry> options)
    {
        var shapes = picture.ShapeContainer.Children.OfType<DocSharp.Binary.OfficeDrawing.Shape>().ToArray();
        if (picture.mfp.mm != 100 || shapes.Length != 1 || shapes[0].Instance != 1 ||
            shapes[0].fGroup || shapes[0].fDeleted || shapes[0].fOleShape || shapes[0].fHaveMaster ||
            picture.dxaCropLeft != 0 || picture.dxaCropRight != 0 ||
            picture.dyaCropTop != 0 || picture.dyaCropBottom != 0 ||
            picture.dxaGoal <= 0 || picture.dyaGoal <= 0 ||
            options.Count() != 3 || options.Any(option => option.opComplex != null)) return null;

        // Word also stores some separators as inline rectangles with a solid
        // RGB fill and an explicitly disabled outline, without a rule flag.
        var color = options.FirstOrDefault(option => option.pid == ShapeOptions.PropertyId.fillColor);
        var fill = options.FirstOrDefault(option => option.pid == ShapeOptions.PropertyId.FillStyleBooleanProperties);
        var stroke = options.FirstOrDefault(option => option.pid == ShapeOptions.PropertyId.lineStyleBooleans);
        if (color.pid != ShapeOptions.PropertyId.fillColor || color.op > 0xffffff ||
            fill.op != 0x00100010 || stroke.op != 0x00080000) return null;

        // PICMID stores scale factors in tenths of a percent.
        var width = ((long)picture.dxaGoal * picture.mx + 500) / 1000;
        var height = ((long)picture.dyaGoal * picture.my + 500) / 1000;
        if (width < 320 || width > 28800 || height < 15 || height > 120 || width < height * 16) return null;
        var rgb = (int)color.op;
        return new HorizontalRule { Width = (int)width, Height = (int)height, Solid = true,
            Color = Color.FromArgb(rgb & 255, (rgb >> 8) & 255, (rgb >> 16) & 255) };
    }

    private static List<HorizontalRule> ReadHorizontalRules(WordDocument source, IEnumerable<XElement> pictures,
        int slotCount)
    {
        // Group Shape Boolean Properties stores values and their use bits in
        // separate halves. Leave pictures with stored image data to DocSharp.
        const uint Rule = 0x08000800, Standard = 0x20002000, NoShade = 0x10001000;
        var rules = new List<HorizontalRule>();
        var expectedEmpty = new List<bool>();
        var requireExactMapping = false;
        var hasUnknownPicture = false;
        var length = Math.Min(source.Text.Count, source.FIB.ccpText);
        for (var cp = 0; cp < length; cp++)
        {
            if (source.Text[cp] != '\u0001') continue;
            var view = ReadInlinePicture(source, cp);
            if (view == null) continue;
            if (view.mfp.mm <= 98 || view.ShapeContainer == null)
            {
                hasUnknownPicture = true;
                continue;
            }
            if (view.BlipStoreEntry != null)
            {
                expectedEmpty.Add(false);
                continue;
            }
            var options = view.ShapeContainer.ExtractOptions();
            var flags = options.FirstOrDefault(x => x.pid == ShapeOptions.PropertyId.groupShapeBooleans).op;
            if ((flags & (Rule | Standard)) != (Rule | Standard))
            {
                // A linked picture may lack a stored preview. Keep its empty
                // slot so the following rule cannot replace the wrong object.
                if (options.Any(x => x.pid == ShapeOptions.PropertyId.pibName && x.opComplex != null) &&
                    options.Any(x => x.pid == ShapeOptions.PropertyId.pibFlags && x.op == 2) &&
                    !options.Any(x => x.pid == ShapeOptions.PropertyId.Pib))
                {
                    if (rules.Count >= slotCount) return null;
                    requireExactMapping = true;
                    expectedEmpty.Add(true);
                    rules.Add(null);
                }
                else
                {
                    var inline = ReadSolidInlineRule(view, options);
                    if (inline == null) hasUnknownPicture = true;
                    else
                    {
                        if (rules.Count >= slotCount) return null;
                        requireExactMapping = true;
                        expectedEmpty.Add(true);
                        rules.Add(inline);
                    }
                }
                continue;
            }
            var color = options.FirstOrDefault(x => x.pid == ShapeOptions.PropertyId.fillColor);
            var alignment = options.FirstOrDefault(x => x.pid == ShapeOptions.PropertyId.alignHR);
            var ratio = options.FirstOrDefault(x => x.pid == ShapeOptions.PropertyId.pctHR).op;
            var width = options.FirstOrDefault(x => x.pid == ShapeOptions.PropertyId.dxWidthHR).op;
            var height = options.FirstOrDefault(x => x.pid == ShapeOptions.PropertyId.dxHeightHR).op;
            // Word can omit alignHR and let the inline rule follow its paragraph.
            if (color.pid != ShapeOptions.PropertyId.fillColor || color.op > 0xffffff ||
                (alignment.pid == ShapeOptions.PropertyId.alignHR && alignment.op != 1) ||
                height == 0 || height > 720 || ratio > 1000 || width > 57600) return null;
            var rgb = (int)color.op;
            rules.Add(new HorizontalRule { Color = Color.FromArgb(rgb & 255, (rgb >> 8) & 255, (rgb >> 16) & 255),
                Height = (int)height, Width = (int)width,
                Percentage = ratio == 0 && width == 0 ? 1000 : (int)ratio,
                Solid = (flags & NoShade) == NoShade });
            expectedEmpty.Add(true);
            if (rules.Count > slotCount) return null;
        }
        if (rules.Count != slotCount) return null;
        if (requireExactMapping)
        {
            if (hasUnknownPicture || !pictures.Select(IsEmptyPicture).SequenceEqual(expectedEmpty) ||
                pictures.Any(picture => !IsEmptyPicture(picture) && !picture.Descendants(V + "imagedata")
                    .Any(image => !String.IsNullOrEmpty((string)image.Attribute(R + "id"))))) return null;
        }
        return rules;
    }

    private static int WordTwips(XElement element, string property, int fallback)
    {
        int value;
        return element != null && Int32.TryParse((string)element.Attribute(W + property),
            NumberStyles.Integer, CultureInfo.InvariantCulture, out value) ? value : fallback;
    }

    private static int SectionWidth(XElement section)
    {
        if (section == null || WordTwips(section.Element(W + "cols"), "num", 1) != 1) return 0;
        var margins = section.Element(W + "pgMar");
        var width = WordTwips(section.Element(W + "pgSz"), "w", 0);
        var available = (long)width - WordTwips(margins, "left", 1440) -
            WordTwips(margins, "right", 1440) - WordTwips(margins, "gutter", 0);
        return available >= 300 && available <= 57600 ? (int)available : 0;
    }

    private static void AddHorizontalRules(ZipArchive archive, XElement body, WordDocument source,
        XDocument relationships, HashSet<string> ids, HashSet<string> drawingIds,
        Dictionary<string, byte[]> images)
    {
        var pictures = body.Descendants(W + "pict");
        var slots = pictures.Where(IsEmptyPicture).Take(513).ToArray();
        if (slots.Length == 0 || slots.Length > 512 ||
            slots.Any(n => n.Parent == null || n.Parent.Name != W + "r" || n.Ancestors(W + "txbxContent").Any()))
            return;
        var rules = ReadHorizontalRules(source, pictures, slots.Length);
        if (rules == null || slots.Where((slot, index) => rules[index] != null)
            .Any(slot => slot.Ancestors(W + "tc").Any())) return;
        var slotSet = new HashSet<XElement>(slots);
        var widths = new Dictionary<XElement, int>();
        var available = SectionWidth(body.Element(W + "sectPr"));
        foreach (var block in body.Elements().Reverse())
        {
            var paragraph = block.Element(W + "pPr");
            var section = paragraph == null ? null : paragraph.Element(W + "sectPr");
            if (section != null) available = SectionWidth(section);
            foreach (var slot in block.Descendants(W + "pict").Where(slotSet.Contains)) widths.Add(slot, available);
        }
        var resources = new Dictionary<Tuple<int,int,int,bool>, string>();
        var ordinal = 0;
        for (var index = 0; index < rules.Count; index++)
        {
            var rule = rules[index];
            if (rule == null) continue;
            var section = 0;
            widths.TryGetValue(slots[index], out section);
            var width = rule.Percentage == 0 ? rule.Width : section * rule.Percentage / 1000;
            if (width <= 0) continue;
            var size = new Size(Math.Max(1, (width + 7) / 15), Math.Max(1, (rule.Height + 7) / 15));
            var key = Tuple.Create(size.Width, size.Height, rule.Color.ToArgb(), rule.Solid);
            string id;
            if (!resources.TryGetValue(key, out id))
            {
                string name;
                do
                {
                    id = "rIdHomeLibreRule" + (++ordinal).ToString(CultureInfo.InvariantCulture);
                    name = "word/media/" + id + ".png";
                }
                while (ids.Contains(id) || archive.GetEntry(name) != null);
                ids.Add(id);
                resources.Add(key, id);
                byte[] data;
                using (var bitmap = new Bitmap(size.Width, size.Height, PixelFormat.Format24bppRgb))
                using (var stream = new MemoryStream())
                {
                    using (var graphics = Graphics.FromImage(bitmap))
                    {
                        graphics.Clear(rule.Color);
                        if (!rule.Solid && size.Height > 1)
                        {
                            using (var shadow = new Pen(Color.FromArgb(rule.Color.R * 3 / 4,
                                rule.Color.G * 3 / 4, rule.Color.B * 3 / 4)))
                                graphics.DrawLine(shadow, 0, 0, size.Width - 1, 0);
                        }
                    }
                    bitmap.Save(stream, ImageFormat.Png);
                    data = stream.ToArray();
                }
                images.Add(name, data);
                relationships.Root.Add(new XElement(Rel + "Relationship", new XAttribute("Id", id),
                    new XAttribute("Type", R.NamespaceName + "/image"),
                    new XAttribute("Target", "media/" + id + ".png")));
            }
            while (!drawingIds.Add((++ordinal).ToString(CultureInfo.InvariantCulture))) { }
            slots[index].ReplaceWith(ImageDrawing(id, ordinal, width * 635, rule.Height * 635, ""));
        }
    }

    private const float PixelsPerPoint = 96f / 72f;

    private static void PaintAxisRule(Bitmap bitmap, float start, float end, float across, float thickness,
        bool vertical = false)
    {
        var x1 = start * PixelsPerPoint;
        var x2 = end * PixelsPerPoint;
        var y1 = (across - thickness / 2) * PixelsPerPoint;
        var y2 = (across + thickness / 2) * PixelsPerPoint;
        var extent = vertical ? bitmap.Height : bitmap.Width;
        var breadth = vertical ? bitmap.Width : bitmap.Height;
        // Preserve the ink coverage of strokes narrower than a screen pixel.
        for (var column = Math.Max(0, (int)Math.Floor(x1)); column < Math.Min(extent, Math.Ceiling(x2)); column++)
        {
            var horizontal = Math.Min(column + 1, x2) - Math.Max(column, x1);
            var coverage = 0f;
            var painted = 0;
            for (var row = Math.Max(0, (int)Math.Floor(y1)); row < Math.Min(breadth, Math.Ceiling(y2)); row++)
            {
                var crossCoverage = Math.Min(row + 1, y2) - Math.Max(row, y1);
                coverage += 255 * horizontal * crossCoverage;
                var opacity = (int)Math.Round(coverage);
                var alpha = Math.Max(0, Math.Min(255, opacity - painted));
                var x = vertical ? row : column;
                var y = vertical ? column : row;
                var existing = bitmap.GetPixel(x, y).A;
                bitmap.SetPixel(x, y, Color.FromArgb(alpha + existing - (alpha * existing + 127) / 255, 0, 0, 0));
                painted += alpha;
            }
        }
    }

    private static byte[] EncodeRuleImage(Bitmap bitmap)
    {
        using (var stream = new MemoryStream())
        {
            bitmap.Save(stream, ImageFormat.Png);
            return stream.ToArray();
        }
    }

    private sealed class LineStroke
    {
        internal XElement Picture;
        internal string ShapeId;
        internal float Left, Right, Y, Bottom, Thickness;
    }

    private static XElement RuleAnchorRun(XElement paragraph, bool requireText)
    {
        var run = paragraph.Elements().FirstOrDefault(e => e.Name != W + "pPr");
        if (run == null || run.Name != W + "r" ||
            run.Elements().Any(e => e.Name != W + "rPr" && e.Name != W + "pict" &&
                (e.Name != W + "t" || e.Value.Length > 0)) ||
            (requireText && !run.ElementsAfterSelf().Descendants(W + "t").Any(t => !String.IsNullOrWhiteSpace(t.Value)))) return null;
        return run;
    }

    private static LineStroke ReadLine(XElement pict, Regex style)
    {
        var line = pict.Element(V + "line");
        if (line == null || line.ElementsAfterSelf().Any() || line.ElementsBeforeSelf().Any() || line.Nodes().Any() ||
            (string)line.Attribute("type") != "#_x0000_t20" ||
            !style.IsMatch((string)line.Attribute("style") ?? "") ||
            line.Attributes().Any(a => !a.IsNamespaceDeclaration &&
                a.Name != "id" && a.Name != "type" && a.Name != "style" && a.Name != "from" &&
                a.Name != "to" && a.Name != "strokeweight" && a.Name != "filled") ||
            (line.Attribute("filled") != null && (string)line.Attribute("filled") != "f")) return null;
        var from = LinePoint((string)line.Attribute("from"));
        var to = LinePoint((string)line.Attribute("to"));
        var emu = 9525; // Office's default 0.75 pt stroke.
        var weight = (string)line.Attribute("strokeweight");
        if (!from.HasValue || !to.HasValue ||
            (weight != null && !Int32.TryParse(weight, NumberStyles.None,
                CultureInfo.InvariantCulture, out emu))) return null;
        return new LineStroke {
            Picture = pict, ShapeId = (string)line.Attribute("id") ?? "",
            Left = Math.Min(from.Value.X, to.Value.X), Right = Math.Max(from.Value.X, to.Value.X),
            Y = Math.Min(from.Value.Y, to.Value.Y), Bottom = Math.Max(from.Value.Y, to.Value.Y),
            Thickness = emu / 12700f
        };
    }

    private static XElement RegisterRuleImage(ZipArchive archive, XDocument relationships,
        HashSet<string> ids, HashSet<string> drawingIds, Dictionary<string, byte[]> images,
        string prefix, ref int ordinal, Bitmap bitmap, Size? pageTwips = null, string description = "")
    {
        string id, name;
        do
        {
            id = prefix + (++ordinal).ToString(CultureInfo.InvariantCulture);
            name = "word/media/" + id + ".png";
        }
        while (ids.Contains(id) || archive.GetEntry(name) != null);
        ids.Add(id);
        images.Add(name, EncodeRuleImage(bitmap));
        relationships.Root.Add(new XElement(Rel + "Relationship", new XAttribute("Id", id),
            new XAttribute("Type", R.NamespaceName + "/image"),
            new XAttribute("Target", "media/" + id + ".png")));
        var drawing = ordinal;
        while (!drawingIds.Add(drawing.ToString(CultureInfo.InvariantCulture))) drawing++;
        var width = pageTwips.HasValue ? pageTwips.Value.Width * 635 : bitmap.Width * 9525;
        var height = pageTwips.HasValue ? pageTwips.Value.Height * 635 : bitmap.Height * 9525;
        return ImageDrawing(id, drawing, width, height, description);
    }

    private static void InsertRuleImage(ZipArchive archive, XElement paragraph, XDocument relationships,
        HashSet<string> ids, HashSet<string> drawingIds, Dictionary<string, byte[]> images,
        string prefix, ref int ordinal, Bitmap bitmap, Size? pageTwips = null)
    {
        var drawing=RegisterRuleImage(archive,relationships,ids,drawingIds,images,prefix,ref ordinal,bitmap,pageTwips);
        paragraph.AddBeforeSelf(new XElement(W + "p",
            new XElement(W + "pPr", new XElement(W + "keepNext"),
                new XElement(W + "jc", new XAttribute(W + "val", "left"))),
            new XElement(W + "r", drawing)));
    }

    private static bool ReplaceEmptyParagraphRule(ZipArchive archive, XElement paragraph, LineStroke line,
        Dictionary<int, FileShapeAddress> anchors, XDocument relationships,
        HashSet<string> ids, HashSet<string> drawingIds, Dictionary<string, byte[]> images, ref int ordinal)
    {
        if (paragraph.Elements().Any(n => n.Name != W + "pPr" && n.Name != W + "r") ||
            paragraph.Elements(W + "r").Elements().Any(n => n != line.Picture && n.Name != W + "rPr" &&
                (n.Name != W + "t" || !String.IsNullOrWhiteSpace(n.Value)))) return false;
        var anchor = ReadLineAnchor(line, anchors, FileShapeAddress.AnchorType.text, FileShapeAddress.AnchorType.text, false);
        if (anchor == null || anchor.xaLeft < -1440 || line.Right > 720 || line.Right - line.Left < 16 ||
            line.Thickness < .1f || line.Thickness > 8 || line.Y - line.Thickness / 2 < 0 ||
            line.Y + line.Thickness / 2 > 36) return false;
        // Include the part that extends into the left margin and retain its
        // anchor. Replace the existing slot without adding a paragraph.
        var origin = Math.Min(0, anchor.xaLeft);
        var size = new Size(anchor.xaRight - origin, anchor.yaTop + (int)Math.Ceiling(line.Thickness * 10));
        var description = origin == 0 ? "" : String.Format(CultureInfo.InvariantCulture,
            "homelibre-word-line-{0}:{1}:{2}", size.Width, size.Height, origin);
        using (var bitmap = new Bitmap((int)Math.Ceiling(size.Width / 15f),
            (int)Math.Ceiling(size.Height / 15f), PixelFormat.Format32bppArgb))
        {
            PaintAxisRule(bitmap, (anchor.xaLeft - origin) / 20f, size.Width / 20f, line.Y, line.Thickness);
            line.Picture.ReplaceWith(RegisterRuleImage(archive, relationships, ids, drawingIds, images,
                "rIdHomeLibreParagraphRule", ref ordinal, bitmap, size, description));
        }
        var props = paragraph.Element(W + "pPr");
        if (props == null) paragraph.AddFirst(props = new XElement(W + "pPr"));
        var just = props.Element(W + "jc");
        if (just == null)
        {
            just = new XElement(W + "jc");
            var next = props.Elements().FirstOrDefault(n => n.Name.Namespace == W &&
                new[]{"textDirection","textAlignment","textboxTightWrap","outlineLvl","divId","cnfStyle",
                    "rPr","sectPr","pPrChange"}.Contains(n.Name.LocalName));
            if (next == null) props.Add(just);
            else next.AddBeforeSelf(just);
        }
        just.SetAttributeValue(W + "val", "left");
        return true;
    }

    private static bool InsertRuleAfterParagraph(ZipArchive archive, XElement paragraph, LineStroke line,
        Dictionary<int, FileShapeAddress> anchors, int columnWidth, XElement normal, XElement documentDefaults,
        XDocument relationships, HashSet<string> ids, HashSet<string> drawingIds, Dictionary<string, byte[]> images,
        ref int ordinal)
    {
        var anchor = ReadLineAnchor(line, anchors, FileShapeAddress.AnchorType.text, FileShapeAddress.AnchorType.text, false);
        var properties = paragraph.Element(W + "pPr");
        if (anchor == null || normal == null || properties == null || columnWidth <= 0 ||
            line.Thickness < .1f || line.Thickness > 8 || Math.Abs(anchor.xaLeft) > 1440 ||
            anchor.xaRight - anchor.xaLeft < 320 || anchor.xaRight - anchor.xaLeft > 28800 ||
            properties.Elements().Any(n => n.Name != W + "pStyle" && n.Name != W + "rPr" && n.Name != W + "spacing" &&
                n.Name != W + "jc" && n.Name != W + "widowControl" && n.Name != W + "keepNext" && n.Name != W + "keepLines") ||
            properties.Elements(W + "pStyle").Any(n => (string)n.Attribute(W + "val") != "Normal")) return false;
        var textRuns = paragraph.Elements(W + "r").Where(r => r.Elements(W + "t").Any(t => t.Value.Length != 0)).Take(2).ToArray();
        if (textRuns.Length != 1 || paragraph.Elements().Any(n => n.Name != W + "pPr" && n.Name != W + "r") ||
            paragraph.Elements(W + "r").Elements().Any(n => n != line.Picture && n.Name != W + "rPr" && n.Name != W + "t")) return false;
        var textProperties = textRuns[0].Element(W + "rPr");
        if (textProperties != null && textProperties.Elements().Any(n => n.Name.Namespace != W ||
            !new[]{"rFonts","sz","szCs","b","bCs","lang","noProof","color"}.Contains(n.Name.LocalName))) return false;
        var text = String.Concat(textRuns[0].Elements(W + "t").Select(n => n.Value));
        if (text.Length == 0 || text.Length > 512 || text.Any(Char.IsControl)) return false;
        var spacing = properties.Element(W + "spacing");
        var after = WordTwips(spacing,"after",0);
        if (after < 1 || after > 720) return false;
        float before;
        var rowHeight = FigureRowHeight(paragraph,normal,documentDefaults,out before);
        if (rowHeight <= 0) return false;
        var top = line.Y - (rowHeight - after / 20f);
        if (top - line.Thickness / 2 < 0 || top + line.Thickness / 2 > after / 20f) return false;
        using (var font=FigureFont(textProperties,properties.Element(W+"rPr"),normal.Element(W+"rPr")))
        using (var paragraphFont=FigureFont(properties.Element(W+"rPr"),normal.Element(W+"rPr"),documentDefaults))
        using (var bitmap = new Bitmap((anchor.xaRight-anchor.xaLeft+14)/15, (after+14)/15, PixelFormat.Format32bppArgb))
        {
            if (font == null || paragraphFont == null || Math.Abs(font.GetHeight(72)-paragraphFont.GetHeight(72)) > .01f)
                return false;
            using (var graphics = Graphics.FromImage(bitmap))
            {
                graphics.PageUnit = GraphicsUnit.Point;
                if (graphics.MeasureString(text,font,new PointF(0,0),StringFormat.GenericTypographic).Width + font.Size > columnWidth / 20f)
                    return false;
            }
            var width = anchor.xaRight - anchor.xaLeft;
            PaintAxisRule(bitmap,0,width/20f,top,line.Thickness);
            var marker=String.Format(CultureInfo.InvariantCulture,"homelibre-word-line-{0}:{1}:{2}",width,after,anchor.xaLeft);
            var drawing=RegisterRuleImage(archive,relationships,ids,drawingIds,images,"rIdHomeLibreParagraphRuleAfter",
                ref ordinal,bitmap,new Size(width,after),marker);
            paragraph.AddAfterSelf(new XElement(W+"p",new XElement(W+"pPr",
                new XElement(W+"spacing",new XAttribute(W+"before",0),new XAttribute(W+"after",0),
                    new XAttribute(W+"line",after),new XAttribute(W+"lineRule","atLeast")),
                new XElement(W+"ind",new XAttribute(W+"left",anchor.xaLeft),new XAttribute(W+"firstLine",0)),
                new XElement(W+"jc",new XAttribute(W+"val","left"))),new XElement(W+"r",drawing)));
        }
        spacing.SetAttributeValue(W+"after",0);
        line.Picture.Remove();
        return true;
    }

    private static bool InsertRuleAtPageStart(ZipArchive archive, XElement opening, XElement paragraph, LineStroke line,
        Dictionary<int, FileShapeAddress> anchors, int columnWidth, XDocument relationships,
        HashSet<string> ids, HashSet<string> drawingIds, Dictionary<string, byte[]> images, ref int ordinal)
    {
        var anchor = ReadLineAnchor(line, anchors, FileShapeAddress.AnchorType.text, FileShapeAddress.AnchorType.text, false);
        var properties = opening.Element(W + "pPr");
        var spacing = properties == null ? null : properties.Element(W + "spacing");
        var before = WordTwips(spacing, "before", 0) / 20f;
        // A line anchored to the next paragraph can be the rule over the
        // large top gap of an explicitly started printed page.
        if (anchor == null || before < 72 || before > 288 || line.Y > -before - 4 || line.Y < -before - 120 ||
            spacing.Attribute(W + "beforeAutospacing") != null || spacing.Attribute(W + "beforeLines") != null ||
            properties.Element(W + "pBdr") != null || properties.Element(W + "sectPr") != null ||
            properties.Element(W + "pageBreakBefore") != null || columnWidth <= 0 ||
            anchor.xaLeft < 0 || anchor.xaLeft > 1440 || anchor.xaRight > columnWidth + 240 ||
            anchor.xaRight - anchor.xaLeft < columnWidth / 2 || line.Thickness < .1f || line.Thickness > 2.5f ||
            opening.Elements().Any(element => element.Name != W + "pPr" && element.Name != W + "r")) return false;

        var elements = opening.Elements(W + "r").Elements().Where(element => element.Name != W + "rPr" &&
            (element.Name != W + "t" || !String.IsNullOrWhiteSpace(element.Value))).ToArray();
        if (elements.Length < 2 || elements[0].Name != W + "br" || (string)elements[0].Attribute(W + "type") != "page" ||
            elements.Skip(1).Any(element => element.Name != W + "t") ||
            paragraph.Elements(W + "pPr").Elements(W + "pageBreakBefore").Any() ||
            paragraph.Descendants(W + "br").Any(element => (string)element.Attribute(W + "type") == "page")) return false;

        var width = anchor.xaRight - anchor.xaLeft;
        var height = Math.Max(30, (int)Math.Ceiling(line.Thickness * 20) + 15);
        using (var bitmap = new Bitmap((width + 14) / 15, (height + 14) / 15, PixelFormat.Format32bppArgb))
        {
            PaintAxisRule(bitmap, 0, width / 20f, height / 40f, line.Thickness);
            var marker = String.Format(CultureInfo.InvariantCulture, "homelibre-word-line-{0}:{1}:{2}", width, height, anchor.xaLeft);
            var drawing = RegisterRuleImage(archive, relationships, ids, drawingIds, images,
                "rIdHomeLibreParagraphRuleStart", ref ordinal, bitmap, new Size(width, height), marker);
            opening.AddBeforeSelf(new XElement(W + "p", new XElement(W + "pPr",
                new XElement(W + "keepNext"), new XElement(W + "pageBreakBefore"),
                new XElement(W + "spacing", new XAttribute(W + "before", 0), new XAttribute(W + "after", 0),
                    new XAttribute(W + "line", height), new XAttribute(W + "lineRule", "exact")),
                new XElement(W + "ind", new XAttribute(W + "left", anchor.xaLeft), new XAttribute(W + "firstLine", 0)),
                new XElement(W + "jc", new XAttribute(W + "val", "left"))), new XElement(W + "r", drawing)));
        }
        elements[0].Remove();
        line.Picture.Remove();
        return true;
    }

    private static bool InsertRuleInLargeParagraphGap(ZipArchive archive, XElement paragraph, XElement previous,
        LineStroke line, Dictionary<int, FileShapeAddress> anchors, int columnWidth, XElement normal,
        XDocument relationships, HashSet<string> ids, HashSet<string> drawingIds,
        Dictionary<string, byte[]> images, ref int ordinal)
    {
        var properties = paragraph.Element(W + "pPr");
        var spacing = properties == null ? null : properties.Element(W + "spacing");
        var before = WordTwips(spacing, "before", 0);
        if (before <= 720 || before > 1440 || spacing.Attribute(W + "beforeAutospacing") != null ||
            spacing.Attribute(W + "beforeLines") != null || properties.Element(W + "pBdr") != null ||
            properties.Element(W + "pageBreakBefore") != null || properties.Element(W + "sectPr") != null ||
            paragraph.Descendants(W + "br").Any(n => (string)n.Attribute(W + "type") == "page") ||
            paragraph.Descendants(W + "pict").Skip(1).Any() || paragraph.Descendants(W + "drawing").Any() ||
            line.Thickness < .1f || line.Thickness > 2 || line.Y - line.Thickness / 2 < 0 ||
            line.Y + line.Thickness / 2 > before / 20f || line.Right - line.Left < 16) return false;

        var priorProperties = previous.Element(W + "pPr");
        var normalProperties = normal == null ? null : normal.Element(W + "pPr");
        // An adjoining paragraph with trailing space may collapse the gap in
        // Word. Only consume space exclusively assigned to this paragraph.
        var priorStyle = priorProperties == null ? null : priorProperties.Element(W + "pStyle");
        var previousSpacing = previous.Elements(W + "pPr").Elements(W + "spacing")
            .Concat(normalProperties == null ? Enumerable.Empty<XElement>() : normalProperties.Elements(W + "spacing"));
        if ((priorStyle != null && (string)priorStyle.Attribute(W + "val") != "Normal") ||
            properties.Element(W + "contextualSpacing") != null ||
            previousSpacing.Any(s => WordTwips(s, "after", 0) != 0 || s.Attribute(W + "afterLines") != null ||
                s.Attribute(W + "afterAutospacing") != null)) return false;

        var anchor = ReadLineAnchor(line, anchors, FileShapeAddress.AnchorType.text, FileShapeAddress.AnchorType.text);
        if (anchor == null || anchor.xaLeft < 0 || anchor.xaRight > columnWidth) return false;
        // Preserve the blank space to the left and above the ink within the
        // original text column. The whole gap moves with the linked paragraph.
        var width = anchor.xaRight;
        var marker = String.Format(CultureInfo.InvariantCulture, "homelibre-word-line-{0}:{1}:0", width, before);
        using (var bitmap = new Bitmap((width + 14) / 15, (before + 14) / 15, PixelFormat.Format32bppArgb))
        {
            PaintAxisRule(bitmap, line.Left, line.Right, line.Y, line.Thickness);
            var drawing = RegisterRuleImage(archive, relationships, ids, drawingIds, images,
                "rIdHomeLibreParagraphRuleBefore", ref ordinal, bitmap, new Size(width, before), marker);
            paragraph.AddBeforeSelf(new XElement(W + "p", new XElement(W + "pPr",
                new XElement(W + "keepNext"),
                new XElement(W + "spacing", new XAttribute(W + "before", 0), new XAttribute(W + "after", 0),
                    new XAttribute(W + "line", before), new XAttribute(W + "lineRule", "atLeast")),
                new XElement(W + "ind", new XAttribute(W + "left", 0), new XAttribute(W + "firstLine", 0)),
                new XElement(W + "jc", new XAttribute(W + "val", "left"))), new XElement(W + "r", drawing)));
        }
        spacing.SetAttributeValue(W + "before", 0);
        line.Picture.Remove();
        return true;
    }

    private static bool InsertRuleBelowHeading(ZipArchive archive, XElement heading, XElement paragraph,
        Dictionary<int, FileShapeAddress> anchors, int columnWidth, XDocument relationships,
        HashSet<string> ids, HashSet<string> drawingIds, Dictionary<string, byte[]> images, ref int ordinal)
    {
        var firstContent = paragraph.Elements(W + "r").Elements().FirstOrDefault(n =>
            n.Name != W + "rPr" && n.Name != W + "tab" &&
            (n.Name != W + "t" || !String.IsNullOrWhiteSpace(n.Value)));
        if (firstContent == null || firstContent.Name != W + "pict") return false;
        var line = ReadLine(firstContent, LineOrder);
        if (line == null || line.Y != line.Bottom || line.Y < .5f || line.Y > 8 ||
            line.Thickness < .1f || line.Thickness > 2 || line.Y < line.Thickness / 2) return false;
        var anchor = ReadLineAnchor(line, anchors, FileShapeAddress.AnchorType.text, FileShapeAddress.AnchorType.text, false);
        if (anchor == null || anchor.xaLeft < 0 || anchor.xaLeft > 1440 || anchor.xaRight > columnWidth) return false;

        var properties = heading.Element(W + "pPr");
        if (properties == null || properties.Element(W + "pBdr") != null ||
            properties.Element(W + "sectPr") != null || properties.Element(W + "numPr") != null ||
            heading.Elements().Any(n => n.Name != W + "r" && n.Name != W + "pPr") ||
            heading.Elements(W + "r").Elements().Any(n => n.Name != W + "rPr" && n.Name != W + "t")) return false;
        var indent = properties.Element(W + "ind");
        var left = WordTwips(indent, "left", 0) + WordTwips(indent, "firstLine", 0) - WordTwips(indent, "hanging", 0);
        var alignment = (string)properties.Elements(W + "jc").Attributes(W + "val").FirstOrDefault();
        if (Math.Abs(left - anchor.xaLeft) > 20 || (alignment != null && alignment != "left" && alignment != "both") ||
            indent == null || indent.Attributes().Any(a => a.Name.LocalName.EndsWith("Chars", StringComparison.Ordinal)) ||
            !paragraph.Elements(W + "r").Elements(W + "t").Any(n => !String.IsNullOrWhiteSpace(n.Value))) return false;

        // A short label and a stroke starting at the label indent identify an
        // underline, even if Word stores it in the following paragraph.
        var labels = heading.Elements(W + "r").Elements(W + "t").Where(n => !String.IsNullOrWhiteSpace(n.Value)).Take(2).ToArray();
        if (labels.Length != 1) return false;
        var text = labels[0].Value.Trim();
        if (text.Length < 3 || text.Length > 60 || !text.EndsWith(":", StringComparison.Ordinal) || text.Any(Char.IsControl)) return false;
        var style = labels[0].Parent.Element(W + "rPr");
        var width = anchor.xaRight - anchor.xaLeft;
        var height = anchor.yaTop + (int)Math.Ceiling(line.Thickness * 10) + 1;
        if (width < 320 || width > 4800) return false;
        using (var font = FigureFont(style, properties.Element(W + "rPr")))
        using (var bitmap = new Bitmap((width + 14) / 15, (height + 14) / 15, PixelFormat.Format32bppArgb))
        {
            if (font == null) return false;
            using (var graphics = Graphics.FromImage(bitmap))
            {
                graphics.PageUnit = GraphicsUnit.Point;
                var measured = graphics.MeasureString(text, font, new PointF(0, 0), StringFormat.GenericTypographic).Width;
                measured = measured * WordTwips(style == null ? null : style.Element(W + "w"), "val", 100) / 100f +
                    (text.Length - 1) * WordTwips(style == null ? null : style.Element(W + "spacing"), "val", 0) / 20f;
                if (measured <= 0 || width / 20f < measured * .8f || width / 20f > measured * 1.65f) return false;
            }
            PaintAxisRule(bitmap, 0, width / 20f, line.Y, line.Thickness);
            var marker = String.Format(CultureInfo.InvariantCulture, "homelibre-word-line-{0}:{1}:{2}", width, height, anchor.xaLeft);
            var drawing = RegisterRuleImage(archive, relationships, ids, drawingIds, images,
                "rIdHomeLibreParagraphRuleHeading", ref ordinal, bitmap, new Size(width, height), marker);
            paragraph.AddBeforeSelf(new XElement(W + "p", new XElement(W + "pPr",
                new XElement(W + "spacing", new XAttribute(W + "before", 0), new XAttribute(W + "after", 0),
                    new XAttribute(W + "line", height), new XAttribute(W + "lineRule", "atLeast")),
                new XElement(W + "ind", new XAttribute(W + "left", anchor.xaLeft), new XAttribute(W + "firstLine", 0)),
                new XElement(W + "jc", new XAttribute(W + "val", "left"))), new XElement(W + "r", drawing)));
        }
        line.Picture.Remove();
        return true;
    }

    private static void AddParagraphRules(ZipArchive archive, XElement body, WordDocument original, XElement normal,
        XElement documentDefaults, XDocument relationships,
        HashSet<string> ids, HashSet<string> drawingIds, Dictionary<string, byte[]> images)
    {
        var ordinal = 0;
        var anchors = ReadMarginAnchors(original);
        var paragraphs=body.Elements(W+"p").ToArray();
        var widths=new int[paragraphs.Length];
        var width=SectionWidth(body.Element(W+"sectPr"));
        for (var index=paragraphs.Length-1;index>=0;index--)
        {
            var section=paragraphs[index].Elements(W+"pPr").Elements(W+"sectPr").FirstOrDefault();
            if (section!=null) width=SectionWidth(section);
            widths[index]=width;
        }
        for (var index=0;index<paragraphs.Length;index++)
        {
            if (ordinal >= MaxFigures) break;
            var paragraph=paragraphs[index];
            if (index > 0 && paragraphs[index - 1].ElementsAfterSelf().FirstOrDefault() == paragraph &&
                InsertRuleBelowHeading(archive, paragraphs[index - 1], paragraph, anchors, widths[index], relationships,
                    ids, drawingIds, images, ref ordinal)) continue;
            var run = RuleAnchorRun(paragraph, false);
            if (run == null) continue;
            var pictures = run.Elements(W + "pict").Take(2).ToArray();
            if (pictures.Length != 1) continue;
            var line = ReadLine(pictures[0], LineOrder);
            if (line == null || line.Y != line.Bottom) continue;
            if (ReplaceEmptyParagraphRule(archive,paragraph,line,anchors,relationships,ids,drawingIds,images,ref ordinal)) continue;
            if (InsertRuleAfterParagraph(archive,paragraph,line,anchors,widths[index],normal,documentDefaults,
                relationships,ids,drawingIds,images,ref ordinal)) continue;
            if (line.Y < 0 && index > 0 && paragraphs[index - 1].ElementsAfterSelf().FirstOrDefault() == paragraph &&
                InsertRuleAtPageStart(archive, paragraphs[index - 1], paragraph, line, anchors, widths[index],
                    relationships, ids, drawingIds, images, ref ordinal)) continue;
            if (!run.ElementsAfterSelf().Descendants(W+"t").Any(t => !String.IsNullOrWhiteSpace(t.Value))) continue;
            if (index > 0 && paragraphs[index - 1].ElementsAfterSelf().FirstOrDefault() == paragraph &&
                InsertRuleInLargeParagraphGap(archive, paragraph, paragraphs[index - 1], line, anchors, widths[index],
                    normal, relationships, ids, drawingIds, images, ref ordinal)) continue;
            var properties = paragraph.Element(W + "pPr");
            var spacing = properties == null ? null : properties.Element(W + "spacing");
            var before = WordTwips(spacing, "before", 0) / 20f;
            if (before < 3 || before > 36 || spacing.Attribute(W + "beforeAutospacing") != null ||
                spacing.Attribute(W + "beforeLines") != null || properties.Element(W + "pBdr") != null) continue;
            var thickness = line.Thickness;
            var left = line.Left;
            var right = line.Right;
            var y = line.Y;
            // Only a short rule completely inside the space before its text
            // can become an illustration before the same paragraph.
            if (left < -2 || left > 24 || right > 84 || right - left < 16 ||
                thickness < .1f || thickness > 2 || y - thickness / 2 < 0 || y + thickness / 2 > before) continue;
            right -= Math.Min(0, left);
            left = Math.Max(0, left);
            using (var bitmap = new Bitmap((int)Math.Ceiling(right * PixelsPerPoint),
                (int)Math.Ceiling(before * PixelsPerPoint), PixelFormat.Format32bppArgb))
            {
                PaintAxisRule(bitmap, left, right, y, thickness);
                InsertRuleImage(archive, paragraph, relationships, ids, drawingIds, images,
                    "rIdHomeLibreParagraphRule", ref ordinal, bitmap);
            }
            spacing.Attribute(W + "before").Remove();
            pictures[0].Remove();
        }
    }

    private static Dictionary<int, FileShapeAddress> ReadMarginAnchors(WordDocument original)
    {
        var anchors = new Dictionary<int, FileShapeAddress>();
        if (original.OfficeDrawingPlex == null) return anchors;
        var ambiguous = new HashSet<int>();
        foreach (var anchor in original.OfficeDrawingPlex.Elements)
            if (anchors.ContainsKey(anchor.spid)) ambiguous.Add(anchor.spid);
            else anchors.Add(anchor.spid, anchor);
        foreach (var id in ambiguous) anchors.Remove(id);
        return anchors;
    }

    private static bool ReadFigureRow(XElement paragraph, List<XElement> shapes, bool withText=false)
    {
        if (paragraph.Name!=W+"p" || paragraph.Elements().Any(n=>n.Name!=W+"r" && n.Name!=W+"pPr"))
            return false;
        var properties=paragraph.Element(W+"pPr");
        if (properties==null || properties.Elements(W+"pStyle").Any(n=>(string)n.Attribute(W+"val")!="Normal") ||
            properties.Elements().Any(n=>!new[]{"pStyle","rPr","keepNext","keepLines",
            "shd","widowControl","ind","spacing","jc"}.Contains(n.Name.LocalName) || n.Name.Namespace!=W))
            return false;
        foreach (var node in paragraph.Elements(W+"r").SelectMany(r=>r.Elements()))
        {
            if (node.Name==W+"rPr" || node.Name==W+"t" && (withText || String.IsNullOrWhiteSpace(node.Value))) continue;
            if (node.Name!=W+"pict") return false;
            var contents=node.Elements().Where(n=>n.Name!=V+"shapetype").Take(2).ToArray();
            if (contents.Length!=1 || contents[0].Name.Namespace!=V) return false;
            shapes.Add(contents[0]);
        }
        return true;
    }

    private static Font FigureFont(XElement properties, XElement fallback, XElement documentDefaults=null, int defaultHalfPoints=0)
    {
        var sources=new[]{properties,fallback,documentDefaults}.Where(node=>node!=null).ToArray();
        var family=(string)sources.SelectMany(node=>node.Elements(W+"rFonts")).Attributes(W+"ascii").FirstOrDefault();
        var pointSize=sources.SelectMany(node=>node.Elements(W+"sz")).FirstOrDefault();
        var size=WordTwips(pointSize,"val",defaultHalfPoints)/2f;
        if (String.IsNullOrEmpty(family) || size<4 || size>36) return null;
        var weight=sources.SelectMany(node=>node.Elements(W+"b")).FirstOrDefault();
        var bold=weight!=null && !new[]{"0","false","off"}.Contains((string)weight.Attribute(W+"val"));
        var face=new Font(family,size,bold ? FontStyle.Bold : FontStyle.Regular,GraphicsUnit.Point);
        if (String.Equals(face.FontFamily.Name,family,StringComparison.OrdinalIgnoreCase)) return face;
        face.Dispose();
        return null;
    }

    private static float FigureRowHeight(XElement paragraph, XElement normal, XElement documentDefaults, out float before)
    {
        before=0;
        var properties=paragraph.Element(W+"pPr");
        var inherited=normal.Element(W+"pPr");
        var spacing=properties.Element(W+"spacing");
        var normalSpacing=inherited==null ? null : inherited.Element(W+"spacing");
        var spacingAttributes=new[]{spacing,normalSpacing}.Where(node=>node!=null).Attributes().ToArray();
        if (spacingAttributes.Any(a=>!a.IsNamespaceDeclaration &&
            (a.Name.Namespace!=W || !new[]{"lineRule","line","before","after"}.Contains(a.Name.LocalName)))) return 0;
        if (((string)spacingAttributes.FirstOrDefault(a=>a.Name==W+"lineRule")??"auto")!="auto") return 0;
        var line=WordTwips(spacing,"line",WordTwips(normalSpacing,"line",240));
        var upper=WordTwips(spacing,"before",WordTwips(normalSpacing,"before",0));
        var lower=WordTwips(spacing,"after",WordTwips(normalSpacing,"after",0));
        if (line<180 || line>480 || upper<0 || lower<0 || upper>2000 || lower>2000) return 0;
        // These anchors are from the binary DOC. Its before and after spacing is additive.
        before=upper/20f;
        using (var font=FigureFont(properties.Element(W+"rPr"),normal.Element(W+"rPr"),documentDefaults))
            return font==null ? 0 : before+font.GetHeight(72)*line/240f+lower/20f;
    }

    private static bool ReadFigureLabel(XElement box, RectangleF bounds, bool oval, XElement defaults, Shape figure)
    {
        var content=box.Element(W+"txbxContent");
        if (box.Attributes().Any(a=>!a.IsNamespaceDeclaration) || content==null ||
            box.Elements().Count()!=1 || content.Elements().Any(n=>n.Name!=W+"p")) return false;
        var nonempty=content.Elements().Where(p=>p.Descendants(W+"t").Any(t=>!String.IsNullOrWhiteSpace(t.Value)))
            .Take(2).ToArray();
        if (nonempty.Length!=1 || content.Descendants().Any(n=>!new[]{"p","pPr","rPr","pStyle","r","t","sz",
            "szCs","rFonts","b","bCs"}.Contains(n.Name.LocalName) || n.Name.Namespace!=W)) return false;
        var runs=nonempty[0].Elements(W+"r").ToArray();
        var label=String.Concat(runs.Select(n=>String.Concat(n.Elements(W+"t").Select(t=>t.Value)))).Trim();
        if (label.Length==0 || label.Length>96 || label.Any(Char.IsControl)) return false;
        var first=runs[0].Element(W+"rPr");
        if (runs.Any(r=>!XNode.DeepEquals(first,r.Element(W+"rPr")))) return false;
        using (var font=FigureFont(first,defaults))
        {
            if (font==null) return false;
            figure.LabelFont=new Font(font.FontFamily,font.Size,font.Style,GraphicsUnit.Pixel);
        }
        var shrink=oval ? (1-(float)Math.Sqrt(.5))/2 : 0;
        var x=bounds.Width*shrink+7.2f;
        var y=bounds.Height*shrink+3.6f;
        var available=RectangleF.Inflate(bounds,-x,-y);
        if (available.Width<=0 || available.Height<=0) return false;
        figure.LabelBounds=available;
        figure.Label=label;
        return true;
    }

    private static bool ReadCompoundShape(XElement node, Dictionary<int,FileShapeAddress> anchors, float top,
        XElement defaults, Shape shape, Func<string,Bitmap> readPicture=null)
    {
        var id=(string)node.Attribute("id") ?? "";
        var type=(string)node.Attribute("type");
        var raster=readPicture!=null && node.Name==V+"shape" && type=="#_x0000_t75";
        int number;
        FileShapeAddress anchor;
        if (!id.StartsWith("_x0000_s",StringComparison.Ordinal) || !Int32.TryParse(id.Substring(8),out number) ||
            !anchors.TryGetValue(number,out anchor) || anchor.bx!=FileShapeAddress.AnchorType.text ||
            anchor.by!=FileShapeAddress.AnchorType.text || anchor.wr!=(raster ? 1 : 3) || anchor.fRcaSimple || anchor.fBelowText ||
            node.Attributes().Any(a=>!a.IsNamespaceDeclaration && !new[]{"id","type","style","from","to",
                "strokeweight","filled","fillcolor"}.Contains(a.Name.ToString()) && (!raster || a.Name!="stroked"))) return false;
        var options=new Dictionary<string,string>();
        var flipX=false;
        var flipY=false;
        foreach (var token in ((string)node.Attribute("style")??"").Split(';'))
        {
            if (token.Length==0) continue;
            var entry=token.Split(':');
            if (entry.Length!=2) return false;
            if (entry[0]=="flip" && entry[1]=="x" && !flipX) flipX=true;
            else if (entry[0]=="flip" && entry[1]=="y" && !flipY) flipY=true;
            else if (entry[0]=="flip" || options.ContainsKey(entry[0])) return false;
            else options.Add(entry[0],entry[1]);
        }
        string layer;
        if (!options.TryGetValue("z-index",out layer) || !Int32.TryParse(layer,out shape.Layer)) return false;
        var weight=(string)node.Attribute("strokeweight");
        int emu;
        if (weight!=null && (!Int32.TryParse(weight,out emu) || emu<=0 || emu>63500)) return false;
        shape.Stroke=weight==null ? .75f : Int32.Parse(weight,CultureInfo.InvariantCulture)/12700f;
        if (node.Name==V+"line")
        {
            var from=LinePoint((string)node.Attribute("from"));
            var to=LinePoint((string)node.Attribute("to"));
            var stroke=node.Element(V+"stroke");
            if (type!="#_x0000_t20" || !from.HasValue || !to.HasValue || options.Count!=1 ||
                (string)node.Attribute("filled")!="f" || node.Attribute("fillcolor")!=null ||
                Math.Abs(Math.Min(from.Value.X,to.Value.X)*20-anchor.xaLeft)>.1f ||
                Math.Abs(Math.Max(from.Value.X,to.Value.X)*20-anchor.xaRight)>.1f ||
                Math.Abs(Math.Min(from.Value.Y,to.Value.Y)*20-anchor.yaTop)>.1f ||
                Math.Abs(Math.Max(from.Value.Y,to.Value.Y)*20-anchor.yaBottom)>.1f) return false;
            shape.Line=true;
            if (stroke==null)
            {
                if (readPicture==null || node.HasElements) return false;
            }
            else
            {
                if (node.Elements().Count()!=1 || stroke.HasElements ||
                    stroke.Attributes().Any(a=>!a.IsNamespaceDeclaration && a.Name!="endarrow" && a.Name!="startarrow")) return false;
                var startArrow=(string)stroke.Attribute("startarrow");
                var endArrow=(string)stroke.Attribute("endarrow");
                shape.Arrow=startArrow==null && endArrow=="block";
                if (!shape.Arrow)
                {
                    if (readPicture==null || startArrow!=null && startArrow!="open" || endArrow!=null && endArrow!="open" ||
                        startArrow==null && endArrow==null) return false;
                    shape.OpenArrowStart=startArrow=="open";
                    shape.OpenArrowEnd=endArrow=="open";
                }
            }
            shape.Start=new PointF(flipX ? to.Value.X : from.Value.X,top+(flipY ? to.Value.Y : from.Value.Y));
            shape.End=new PointF(flipX ? from.Value.X : to.Value.X,top+(flipY ? from.Value.Y : to.Value.Y));
            shape.Path.AddLine(shape.Start,shape.End);
            return true;
        }
        var oval=node.Name==V+"oval" && type=="#_x0000_t3";
        var triangle=node.Name==V+"shape" && type=="#_x0000_t5";
        var rectangle=node.Name==V+"rect" && type=="#_x0000_t1" || node.Name==V+"shape" && type=="#_x0000_t202";
        var filled=(string)node.Attribute("filled");
        var template=node.Parent.Element(V+"shapetype");
        if (triangle && (template==null || (string)template.Attribute("adj")!="10800" ||
            (string)template.Attribute("path")!="m@0,l,21600r21600,xe")) return false;
        if (!oval && !triangle && !rectangle && !raster || flipX || flipY || node.Attribute("from")!=null || node.Attribute("to")!=null ||
            filled!=null && !new[]{"t","true","1","f","false","0"}.Contains(filled) ||
            !raster && (node.Elements().Any(n=>n.Name!=V+"textbox") || node.Elements().Count()>1) ||
            options.Keys.Any(n=>!new[]{"position","margin-left","margin-top",
                "width","height","z-index","rotation"}.Contains(n))) return false;
        string pos;
        if (!options.TryGetValue("position",out pos) || pos!="absolute") return false;
        var frame=new[]{"margin-left","margin-top","width","height"}.Select(n=>options.ContainsKey(n) ? Points(options[n]) : null).ToArray();
        if (frame.Any(n=>!n.HasValue) || frame[2]<=0 || frame[3]<=0 ||
            Math.Abs(frame[0].Value*20-anchor.xaLeft)>.1f || Math.Abs(frame[1].Value*20-anchor.yaTop)>.1f ||
            Math.Abs((frame[0].Value+frame[2].Value)*20-anchor.xaRight)>.1f ||
            Math.Abs((frame[1].Value+frame[3].Value)*20-anchor.yaBottom)>.1f) return false;
        var fill=(string)node.Attribute("fillcolor");
        if (fill!=null && !new[]{"#000000","#ffffff"}.Contains(fill.ToLowerInvariant())) return false;
        var bounds=new RectangleF(frame[0].Value,top+frame[1].Value,frame[2].Value,frame[3].Value);
        if (raster)
        {
            var wordWrap=XName.Get("wrap","urn:schemas-microsoft-com:office:word");
            var wrap=node.Element(wordWrap);
            var picture=node.Element(V+"imagedata");
            var relation=picture==null ? null : (string)picture.Attribute(R+"id");
            if ((string)node.Attribute("stroked")!="f" || options.ContainsKey("rotation") || node.Elements().Count()!=2 ||
                wrap==null || wrap.HasElements || (string)wrap.Attribute("type")!="topAndBottom" ||
                picture==null || picture.HasElements || picture.Attributes().Any(a=>!a.IsNamespaceDeclaration && a.Name!=R+"id") ||
                String.IsNullOrEmpty(relation)) return false;
            shape.Picture=readPicture(relation);
            if (shape.Picture==null) return false;
            shape.PictureBounds=bounds;
            shape.Path.AddRectangle(bounds);
            return true;
        }
        if (!new[]{"f","false","0"}.Contains(filled))
            shape.Fill=fill=="#000000" ? Color.Black : Color.White;
        if (oval) shape.Path.AddEllipse(bounds);
        else if (triangle) shape.Path.AddPolygon(new[]{new PointF(bounds.X+bounds.Width/2,bounds.Y),
            new PointF(bounds.Right,bounds.Bottom),new PointF(bounds.Left,bounds.Bottom)});
        else shape.Path.AddRectangle(bounds);
        var box=node.Element(V+"textbox");
        string rotation;
        if (options.TryGetValue("rotation",out rotation))
        {
            float angle;
            if (box!=null || !float.TryParse(rotation,NumberStyles.Float,CultureInfo.InvariantCulture,out angle) ||
                !(angle>=-360 && angle<=360)) return false;
            using (var transform=new Matrix())
            {
                transform.RotateAt(angle,new PointF(bounds.X+bounds.Width/2,bounds.Y+bounds.Height/2));
                shape.Path.Transform(transform);
            }
        }
        return box==null || ReadFigureLabel(box,bounds,oval,defaults,shape);
    }

    private static bool InsertCompoundPicture(ZipArchive archive, XElement paragraph, List<Shape> shapes,
        XDocument relationships, HashSet<string> ids, HashSet<string> drawingIds, Dictionary<string,byte[]> images,
        string prefix, ref int ordinal, bool legend)
    {
        if (shapes.Count==0 || shapes.Select(s=>s.Layer).Distinct().Count()!=shapes.Count) return false;
        var bounds=shapes.Select(s=>s.Path.GetBounds()).Aggregate(RectangleF.Union);
        bounds.Inflate(5,5);
        var limit=legend ? 200 : 850;
        if (bounds.Width<=1 || bounds.Height<=1 || bounds.Width>limit || bounds.Height>limit ||
            images.Values.Sum(data=>(long)data.Length)>MaxFigureBytes) return false;
        var width=(int)Math.Ceiling(bounds.Width*Scale);
        var height=(int)Math.Ceiling(bounds.Height*Scale);
        using (var bitmap=new Bitmap(width,height,PixelFormat.Format24bppRgb))
        using (var surface=Graphics.FromImage(bitmap))
        {
            surface.Clear(Color.White);
            surface.PageUnit=GraphicsUnit.Pixel;
            surface.SmoothingMode=SmoothingMode.AntiAlias;
            surface.TextRenderingHint=System.Drawing.Text.TextRenderingHint.AntiAliasGridFit;
            surface.ScaleTransform(Scale,Scale);
            surface.TranslateTransform(-bounds.Left,-bounds.Top);
            using (var format=(StringFormat)StringFormat.GenericTypographic.Clone())
            {
                format.FormatFlags |= StringFormatFlags.NoWrap | StringFormatFlags.MeasureTrailingSpaces;
                foreach (var shape in shapes.Where(s=>s.LabelFont!=null))
                {
                    var extent=surface.MeasureString(shape.Label,shape.LabelFont,Int32.MaxValue,format);
                    if (extent.Width>shape.LabelBounds.Width+1 || extent.Height>shape.LabelBounds.Height+2) return false;
                }
            }
            foreach (var shape in shapes.OrderBy(s=>s.Layer)) shape.Draw(surface);
            var picture=EncodeRuleImage(bitmap);
            if (picture.Length>MaxFigureBytes) return false;
            string id, path;
            do
            {
                id=prefix+(++ordinal).ToString(CultureInfo.InvariantCulture);
                path="word/media/"+id+".png";
            }
            while (ids.Contains(id) || archive.GetEntry(path)!=null);
            ids.Add(id);
            images.Add(path,picture);
            relationships.Root.Add(new XElement(Rel+"Relationship",new XAttribute("Id",id),
                new XAttribute("Type",R.NamespaceName+"/image"),new XAttribute("Target",path.Substring(5))));
            var drawing=ordinal;
            while (!drawingIds.Add(drawing.ToString(CultureInfo.InvariantCulture))) drawing++;
            var label=String.Join(shapes.Any(s=>s.Caption) ? "\n" : "; ",shapes.Where(s=>s.Label!=null).Select(s=>s.Label));
            var block=ImageParagraph(id,drawing,bitmap.Size,label);
            if (legend || shapes.Any(s=>s.Caption)) block.AddFirst(new XElement(W+"pPr",
                new XElement(W+"keepNext"),new XElement(W+"jc",new XAttribute(W+"val","left"))));
            paragraph.AddBeforeSelf(block);
            return true;
        }
    }

    private static Bitmap ReadScenePicture(ZipArchive archive, XDocument relationships, string id)
    {
        var relation=relationships.Root.Elements(Rel+"Relationship").FirstOrDefault(node=>
            (string)node.Attribute("Id")==id && (string)node.Attribute("Type")==R.NamespaceName+"/image" &&
            node.Attribute("TargetMode")==null);
        var path=relation==null ? "" : ((string)relation.Attribute("Target") ?? "").TrimStart('/');
        if (path.StartsWith("media/",StringComparison.Ordinal)) path="word/"+path;
        if (!Regex.IsMatch(path,@"^word/media/[A-Za-z0-9_.-]+\.png$",RegexOptions.IgnoreCase)) return null;
        var entry=archive.GetEntry(path);
        if (entry==null || entry.Length<33 || entry.Length>2*1024*1024) return null;
        using (var copy=new MemoryStream())
        {
            using (var stream=entry.Open()) stream.CopyTo(copy);
            var header=copy.GetBuffer();
            if (!header.Take(8).SequenceEqual(new byte[]{137,80,78,71,13,10,26,10}) ||
                header[16]!=0 || header[17]!=0 || header[18]>8 || header[20]!=0 || header[21]!=0 || header[22]>8) return null;
            copy.Position=0;
            try
            {
                using (var original=Image.FromStream(copy,false,true))
                {
                    if (original.Width>2048 || original.Height>2048) return null;
                    return new Bitmap(original);
                }
            }
            catch (ArgumentException) { return null; }
        }
    }

    private static bool ReadSceneCaption(XElement paragraph, XElement normal, XElement defaults,
        Graphics measure, float y, int index, Shape caption)
    {
        var paragraphProps=paragraph.Element(W+"pPr");
        var inherited=new XElement(W+"rPr",new[]{paragraphProps.Element(W+"rPr"),normal}.Where(p=>p!=null)
            .SelectMany(p=>p.Elements()).GroupBy(p=>p.Name).Select(p=>p.First()));
        var runs=paragraph.Elements(W+"r").Where(run=>run.Elements(W+"t").Any(node=>node.Value.Length>0)).ToArray();
        if (runs.Length==0 || runs.Any(run=>run.Elements().Any(node=>node.Name!=W+"t" && node.Name!=W+"rPr"))) return false;
        var text=String.Concat(runs.SelectMany(run=>run.Elements(W+"t")).Select(node=>node.Value));
        if (String.IsNullOrWhiteSpace(text) || text.Length>512 || text.Any(Char.IsControl)) return false;
        foreach (var run in runs)
        {
            var props=run.Element(W+"rPr");
            if (props!=null && props.Elements().Any(p=>p.Name!=W+"rFonts" && p.Name!=W+"sz" && p.Name!=W+"lang" &&
                p.Name!=W+"b" && p.Name!=W+"bCs")) return false;
            // MS-DOC sprmCHps defaults to 20 half-points when no style specifies it.
            using (var font=FigureFont(props,inherited,defaults,20))
            {
                if (font==null) return false;
                if (caption.LabelFont==null)
                    caption.LabelFont=new Font(font.FontFamily,font.Size,font.Style,GraphicsUnit.Pixel);
                else if (font.Name!=caption.LabelFont.Name || font.Size!=caption.LabelFont.Size || font.Style!=caption.LabelFont.Style)
                    return false;
            }
        }
        using (var format=(StringFormat)StringFormat.GenericTypographic.Clone())
        {
            format.FormatFlags |= StringFormatFlags.NoWrap | StringFormatFlags.MeasureTrailingSpaces;
            var size=measure.MeasureString(text,caption.LabelFont,Int32.MaxValue,format);
            if (size.Width<=0 || size.Height<=0 || size.Width>800 || size.Height>60) return false;
            caption.LabelBounds=new RectangleF(0,y,size.Width+2,size.Height+1);
        }
        caption.Layer=Int32.MinValue+index;
        caption.Caption=true;
        caption.Label=text;
        caption.Path.AddRectangle(caption.LabelBounds);
        return true;
    }

    private static void AddCaptionedFigures(ZipArchive archive, XElement body, XElement normal, XElement documentDefaults,
        Dictionary<int,FileShapeAddress> anchors, XDocument relationships, HashSet<string> ids,
        HashSet<string> drawingIds, Dictionary<string,byte[]> images)
    {
        var paragraphs=body.Elements().ToArray();
        var defaults=normal.Element(W+"rPr");
        var ordinal=0;
        var nodes=new List<XElement>();
        using (var probe=new Bitmap(1,1))
        using (var measure=Graphics.FromImage(probe))
        {
            measure.PageUnit=GraphicsUnit.Pixel;
            measure.TextRenderingHint=System.Drawing.Text.TextRenderingHint.AntiAliasGridFit;
            for (var start=0; start<paragraphs.Length && ordinal<MaxFigures; start++)
            {
                if (!paragraphs[start].Descendants(V+"imagedata").Any()) continue;
                var shapes=new List<Shape>();
                var top=0f;
                var drawingTop=0f;
                var end=start;
                var complete=true;
                var pictureSeen=false;
                Func<string,Bitmap> readPicture=id=>
                {
                    if (pictureSeen) return null;
                    var picture=ReadScenePicture(archive,relationships,id);
                    pictureSeen=picture!=null;
                    return picture;
                };
                var indent=paragraphs[start].Elements(W+"pPr").Elements(W+"ind").FirstOrDefault();
                try
                {
                    for (; end<paragraphs.Length && end-start<8; end++)
                    {
                        var row=paragraphs[end];
                        if (!row.Descendants(W+"pict").Any()) break;
                        nodes.Clear();
                        var rowIndent=row.Elements(W+"pPr").Elements(W+"ind").FirstOrDefault();
                        if (!ReadFigureRow(row,nodes,true) || nodes.Count==0 || !XNode.DeepEquals(indent,rowIndent) ||
                            row.Elements(W+"pPr").Elements(W+"spacing").Any() || shapes.Count+nodes.Count>64)
                        { complete=false; break; }
                        var caption=new Shape();
                        shapes.Add(caption);
                        if (!ReadSceneCaption(row,defaults,documentDefaults,measure,top,end-start,caption))
                        { complete=false; break; }
                        var nextDrawingTop=top+caption.LabelFont.GetHeight(72);
                        var rowBottom=nextDrawingTop;
                        foreach (var node in nodes)
                        {
                            var shape=new Shape();
                            shapes.Add(shape);
                            if (!ReadCompoundShape(node,anchors,drawingTop,defaults,shape,readPicture))
                            { complete=false; break; }
                            if (shape.Picture!=null) rowBottom=Math.Max(rowBottom,shape.PictureBounds.Bottom);
                        }
                        if (!complete) break;
                        // Legacy Word sets the next paragraph's drawing anchors before
                        // top/bottom wrapping moves that paragraph's text below the bitmap.
                        drawingTop=nextDrawingTop;
                        top=rowBottom;
                    }
                    if (complete && end-start>=2 && end-start<8 && pictureSeen &&
                        shapes.Any(s=>s.OpenArrowStart || s.OpenArrowEnd) &&
                        InsertCompoundPicture(archive,paragraphs[start],shapes,relationships,ids,drawingIds,images,
                            "rIdHomeLibreCompoundCaptioned",ref ordinal,false))
                    {
                        for (var index=start; index<end; index++) paragraphs[index].Remove();
                        start=end-1;
                    }
                }
                finally { foreach (var shape in shapes) shape.Dispose(); }
            }
        }
    }

    private static void AddCompoundLegends(ZipArchive archive, XElement[] paragraphs, XElement normal, XElement documentDefaults,
        Dictionary<int,FileShapeAddress> anchors, XDocument relationships, HashSet<string> ids,
        HashSet<string> drawingIds, Dictionary<string,byte[]> images)
    {
        var ordinal=0;
        var defaults=normal.Element(W+"rPr");
        for (var heading=0; heading<paragraphs.Length && ordinal<MaxFigures; heading++)
        {
            var title=String.Concat(paragraphs[heading].Elements(W+"r").Elements(W+"t").Select(t=>t.Value)).Trim();
            if (!new[]{"Условные обозначения:","Legend:","Key:"}.Contains(title,StringComparer.OrdinalIgnoreCase))
                continue;
            var pending=new List<XElement>();
            var shapes=new List<Shape>();
            var nodes=new List<XElement>();
            var top=0f;
            try
            {
                for (var row=heading+1; row<paragraphs.Length && row<=heading+6; row++)
                {
                    var paragraph=paragraphs[row];
                    nodes.Clear();
                    if (!ReadFigureRow(paragraph,nodes,true) || pending.Count+nodes.Count>16) break;
                    float before;
                    var line=FigureRowHeight(paragraph,normal,documentDefaults,out before);
                    if (line<=0 || top+line>200) break;
                    var valid=true;
                    foreach (var node in nodes)
                    {
                        var figure=new Shape();
                        shapes.Add(figure);
                        if (node.Element(V+"textbox")!=null || !ReadCompoundShape(node,anchors,top+before,defaults,figure))
                        {
                            valid=false;
                            break;
                        }
                        pending.Add(node.Parent);
                    }
                    if (!valid) break;
                    if (paragraph.Elements(W+"r").Elements(W+"t").Any(n=>!String.IsNullOrWhiteSpace(n.Value)))
                    {
                        if (InsertCompoundPicture(archive,paragraph,shapes,relationships,ids,drawingIds,images,
                            "rIdHomeLibreCompoundLegend",ref ordinal,true))
                            foreach (var pict in pending) pict.Remove();
                        foreach (var shape in shapes) shape.Dispose();
                        shapes.Clear();
                        pending.Clear();
                        top=0;
                    }
                    else top+=line;
                }
            }
            finally { foreach (var shape in shapes) shape.Dispose(); }
        }
    }

    private static void AddCompoundFigures(ZipArchive archive, XElement body, XElement normal, XElement documentDefaults,
        Dictionary<int,FileShapeAddress> anchors, XDocument relationships, HashSet<string> ids,
        HashSet<string> drawingIds, Dictionary<string,byte[]> images)
    {
        if (normal==null || anchors.Count==0) return;
        AddCaptionedFigures(archive,body,normal,documentDefaults,anchors,relationships,ids,drawingIds,images);
        var defaults=normal.Element(W+"rPr");
        var paragraphs=body.Elements().ToArray();
        var ordinal=0;
        for (var start=0; start<paragraphs.Length && ordinal<MaxFigures; start++)
        {
            if (!paragraphs[start].Descendants(W+"pict").Any()) continue;
            var shapes=new List<Shape>();
            var nodes=new List<XElement>();
            var top=0f;
            var end=start;
            var lastDrawingRow=start;
            var supported=true;
            try
            {
                for (; end<paragraphs.Length && end-start<32; end++)
                {
                    nodes.Clear();
                    if (!ReadFigureRow(paragraphs[end],nodes)) break;
                    if (!supported) continue;
                    float before;
                    var line=FigureRowHeight(paragraphs[end],normal,documentDefaults,out before);
                    if (line<=0 || top+line>850 || shapes.Count+nodes.Count>128)
                    {
                        supported=false;
                        continue;
                    }
                    foreach (var node in nodes)
                    {
                        var shape=new Shape();
                        shapes.Add(shape);
                        if (ReadCompoundShape(node,anchors,top+before,defaults,shape)) continue;
                        supported=false;
                        break;
                    }
                    if (nodes.Count>0) lastDrawingRow=end;
                    top+=line;
                }
                if (!supported)
                {
                    start=Math.Max(start,end-1);
                    continue;
                }
                var outlinesOnly=shapes.All(s=>!s.Line && s.Fill.A==0 && s.Label==null);
                if (end>start && end-start<32 && shapes.Count>=3 && (outlinesOnly || shapes.Any(s=>s.Label!=null)) &&
                    InsertCompoundPicture(archive,paragraphs[start],shapes,relationships,ids,drawingIds,images,
                        "rIdHomeLibreCompoundFigure",ref ordinal,false))
                {
                    // Trailing empty paragraphs are outside this drawing and keep their spacing.
                    var last=outlinesOnly ? lastDrawingRow : end-1;
                    for (var index=start; index<=last; index++) paragraphs[index].Remove();
                    start=end-1;
                }
            }
            finally { foreach (var shape in shapes) shape.Dispose(); }
        }
        AddCompoundLegends(archive,body.Elements().ToArray(),normal,documentDefaults,anchors,relationships,ids,drawingIds,images);
    }

    private static FileShapeAddress ReadLineAnchor(LineStroke line, Dictionary<int, FileShapeAddress> anchors,
        FileShapeAddress.AnchorType horizontal, FileShapeAddress.AnchorType vertical, bool belowText = true)
    {
        // Verify the origin, coordinates and no-wrap behaviour in the binary source.
        const string Prefix = "_x0000_s";
        int id;
        FileShapeAddress anchor;
        if (!line.ShapeId.StartsWith(Prefix, StringComparison.Ordinal) ||
            !Int32.TryParse(line.ShapeId.Substring(Prefix.Length), NumberStyles.None, CultureInfo.InvariantCulture, out id) ||
            !anchors.TryGetValue(id, out anchor) || anchor.bx != horizontal || anchor.by != vertical || anchor.wr != 3 ||
            anchor.fRcaSimple || anchor.fBelowText != belowText ||
            Math.Abs(anchor.xaLeft - line.Left * 20) > .1f || Math.Abs(anchor.xaRight - line.Right * 20) > .1f ||
            Math.Abs(anchor.yaTop - line.Y * 20) > .1f || Math.Abs(anchor.yaBottom - line.Bottom * 20) > .1f) return null;
        return anchor;
    }

    private static FileShapeAddress ReadMarginAnchor(LineStroke line, Dictionary<int, FileShapeAddress> anchors)
    {
        return ReadLineAnchor(line, anchors, FileShapeAddress.AnchorType.margin, FileShapeAddress.AnchorType.text);
    }

    private static void AddMarginRules(ZipArchive archive, XElement body, Dictionary<int, FileShapeAddress> anchors,
        XDocument relationships, HashSet<string> ids, HashSet<string> drawingIds, Dictionary<string, byte[]> images)
    {
        var ordinal = 0;
        foreach (var paragraph in body.Elements(W + "p"))
        {
            if (ordinal >= MaxFigures) break;
            var run = RuleAnchorRun(paragraph, false);
            if (run == null) continue;
            var lines = new List<LineStroke>();
            foreach (var pict in run.Elements(W + "pict"))
            {
                var line = ReadLine(pict, MarginLineOrder);
                if (line == null || line.Y != line.Bottom || line.Left < -2 || line.Right > 720 || line.Right - line.Left < 16 ||
                    line.Thickness < .1f || line.Thickness > 2.5f ||
                    line.Y + line.Thickness / 2 > 0 || line.Y - line.Thickness / 2 < -36) continue;
                if (ReadMarginAnchor(line, anchors) == null) continue;
                lines.Add(line);
            }
            if (lines.Count == 0 || lines.Count > 16) continue;
            var origin = Math.Min(0, lines.Min(line => line.Left));
            var top = lines.Min(line => line.Y - line.Thickness / 2);
            var right = lines.Max(line => line.Right);
            using (var bitmap = new Bitmap((int)Math.Ceiling((right - origin) * PixelsPerPoint),
                (int)Math.Ceiling(-top * PixelsPerPoint), PixelFormat.Format32bppArgb))
            {
                foreach (var line in lines)
                    PaintAxisRule(bitmap, line.Left - origin, line.Right - origin, line.Y - top, line.Thickness);
                InsertRuleImage(archive, paragraph, relationships, ids, drawingIds, images,
                    "rIdHomeLibreParagraphRuleMargin", ref ordinal, bitmap);
            }
            foreach (var line in lines) line.Picture.Remove();
        }
    }

    private static string MarginRuleName(XElement section, int x, float halfStroke, bool outsideTextOnly)
    {
        if (section == null) return null;
        var margins = section.Element(W + "pgMar");
        var width = WordTwips(section.Element(W + "pgSz"), "w", 0);
        var right = WordTwips(margins, "right", 1440);
        var left = WordTwips(margins, "left", 1440);
        var gutter = WordTwips(margins, "gutter", 0);
        if (width < 300 || width > 57600 || right < 0 || left < 0 || gutter < 0) return null;
        var available = width - (long)left - right - gutter;
        if (x < 0 || available < 300) return null;
        if (right > 0 && x >= available && x <= available + right &&
            (!outsideTextOnly || (x >= available + halfStroke && x + halfStroke <= available + right)))
            return String.Format(CultureInfo.InvariantCulture, "HomeLibreMarginRule-right-{0}-{1}", x - available, right);

        // Foreground strokes can only use the outside margin. A stroke over
        // either column's content would require a page layout to retain it.
        if (outsideTextOnly) return null;
        var columns = section.Element(W + "cols");
        var count = WordTwips(columns, "num", 1);
        if (count != 2) return null;
        var sizes = columns.Elements(W + "col").Take(3).ToArray();
        var gap = WordTwips(sizes.Length == 2 ? sizes[0] : columns, "space", 720);
        var boundary = sizes.Length == 2 ? WordTwips(sizes[0], "w", 0) : (available - gap) / 2;
        var gapEnd = boundary + gap;
        if (gap > 0 && boundary > 0 && gapEnd < available && x >= boundary && x <= gapEnd)
            return String.Format(CultureInfo.InvariantCulture, "HomeLibreMarginRule-left-{0}-{1}", gapEnd - x, gap);
        return null;
    }

    private static XElement MarginRuleDrawing(string id, string name, int number, FileShapeAddress anchor, int thickness)
    {
        var height = (anchor.yaBottom - anchor.yaTop) * 635;
        var drawing = ImageDrawing(id, number, thickness, height, "");
        var position = drawing.Element(WP + "inline");
        position.Name = WP + "anchor";
        position.SetAttributeValue("simplePos", "0");
        position.SetAttributeValue("relativeHeight", "0");
        position.SetAttributeValue("behindDoc", anchor.fBelowText ? "1" : "0");
        position.SetAttributeValue("locked", "0");
        position.SetAttributeValue("layoutInCell", "1");
        position.SetAttributeValue("allowOverlap", "1");
        position.AddFirst(
            new XElement(WP + "simplePos", new XAttribute("x", 0), new XAttribute("y", 0)),
            new XElement(WP + "positionH", new XAttribute("relativeFrom", "margin"),
                new XElement(WP + "posOffset", anchor.xaLeft * 635 - thickness / 2)),
            new XElement(WP + "positionV", new XAttribute("relativeFrom", "paragraph"),
                new XElement(WP + "posOffset", anchor.yaTop * 635)));
        position.Element(WP + "extent").AddAfterSelf(new XElement(WP + "wrapNone"));
        position.Element(WP + "docPr").SetAttributeValue("name", name);
        return drawing;
    }

    private static void AddVerticalMarginRules(ZipArchive archive, XElement body, Dictionary<int, FileShapeAddress> anchors,
        XDocument relationships, HashSet<string> ids, HashSet<string> drawingIds, Dictionary<string, byte[]> images)
    {
        var section = body.Element(W + "sectPr");
        string id = null;
        var number = 0;
        foreach (var paragraph in body.Elements(W + "p").Reverse())
        {
            var props = paragraph.Element(W + "pPr");
            var change = props == null ? null : props.Element(W + "sectPr");
            if (change != null) section = change;
            var firstRun = RuleAnchorRun(paragraph, false);
            if (section == null) continue;
            var firstContent = paragraph.Elements().FirstOrDefault(element => element.Name != W + "pPr");
            if (firstContent == null) continue;
            foreach (var pict in paragraph.Elements(W + "r").Elements(W + "pict").ToArray())
            {
                var line = ReadLine(pict, MarginLineOrder);
                if (line == null || line.Left != line.Right || line.Y < -72 || line.Bottom > 720 ||
                    line.Bottom - line.Y < 8 || line.Thickness < .1f || line.Thickness > 5) continue;
                var anchor = ReadMarginAnchor(line, anchors) ??
                    ReadLineAnchor(line, anchors, FileShapeAddress.AnchorType.margin, FileShapeAddress.AnchorType.text, false);
                if (anchor == null) continue;
                var name = MarginRuleName(section, anchor.xaLeft, line.Thickness * 10, !anchor.fBelowText);
                if (name == null) continue;
                if (id == null)
                {
                    string file;
                    var ordinal = 0;
                    do {
                        id = "rIdHomeLibreVerticalMarginRule" + (++ordinal).ToString(CultureInfo.InvariantCulture);
                        file = "word/media/" + id + ".png";
                    } while (ids.Contains(id) || archive.GetEntry(file) != null);
                    ids.Add(id);
                    using (var pixel = new Bitmap(1, 1, PixelFormat.Format24bppRgb))
                    {
                        pixel.SetPixel(0, 0, Color.Black);
                        images.Add(file, EncodeRuleImage(pixel));
                    }
                    relationships.Root.Add(new XElement(Rel + "Relationship", new XAttribute("Id", id),
                        new XAttribute("Type", R.NamespaceName + "/image"),
                        new XAttribute("Target", "media/" + id + ".png")));
                }
                while (!drawingIds.Add((++number).ToString(CultureInfo.InvariantCulture))) { }
                var drawing = MarginRuleDrawing(id, name, number, anchor, (int)Math.Round(line.Thickness * 12700));
                if (pict.Parent == firstRun) pict.ReplaceWith(drawing);
                else
                {
                    // The VML record can follow text in the source run list.
                    // Its vertical reference is still the paragraph start.
                    firstContent.AddBeforeSelf(new XElement(W + "r", drawing));
                    pict.Remove();
                }
            }
        }
    }

    private static LineStroke ReadPageConnector(XElement pict, Dictionary<int, FileShapeAddress> anchors)
    {
        var shape = pict.Element(V + "shape");
        if (shape == null || shape.Nodes().Any() || (string)shape.Attribute("type") != "#_x0000_t32" ||
            shape.Attributes().Any(a => !a.IsNamespaceDeclaration && a.Name != "id" &&
                a.Name != "type" && a.Name != "style" && a.Name != "strokeweight")) return null;
        var definitions = pict.Elements(V + "shapetype").Take(2).ToArray();
        if (pict.Elements().Count() != 2 || definitions.Length != 1) return null;
        var definition = definitions[0];
        if ((string)definition.Attribute("id") != "_x0000_t32" ||
            (string)definition.Attribute("path") != "m,l21600,21600e" ||
            (string)definition.Attribute("coordsize") != "21600,21600" ||
            (string)definition.Attribute(O + "spt") != "32" ||
            definition.Attributes().Any(a => !a.IsNamespaceDeclaration && a.Name != "id" &&
                a.Name != "path" && a.Name != "coordsize" && a.Name != O + "spt")) return null;
        var stroke = definition.Element(V + "stroke");
        var path = definition.Element(V + "path");
        if (definition.Elements().Count() != 2 || stroke == null || path == null || stroke.Nodes().Any() ||
            path.Nodes().Any() || (string)stroke.Attribute("joinstyle") != "miter" ||
            stroke.Attributes().Any(a => !a.IsNamespaceDeclaration && a.Name != "joinstyle") ||
            path.Attributes().Any(a => !a.IsNamespaceDeclaration && a.Name != O + "connecttype" &&
                a.Name != O + "connectlocs" && a.Name != O + "extrusionok")) return null;
        var style = PageConnectorStyle.Match((string)shape.Attribute("style") ?? "");
        int emu;
        if (!style.Success || !Int32.TryParse((string)shape.Attribute("strokeweight"), NumberStyles.None,
            CultureInfo.InvariantCulture, out emu)) return null;
        var left = Points(style.Groups[1].Value);
        var top = Points(style.Groups[2].Value);
        var width = Points(style.Groups[3].Value);
        var height = Points(style.Groups[4].Value);
        if (!left.HasValue || !top.HasValue || !width.HasValue || !height.HasValue ||
            width < 0 || height < 0 || (width == 0) == (height == 0)) return null;
        var line = new LineStroke {
            Picture = pict, ShapeId = (string)shape.Attribute("id") ?? "",
            Left = left.Value, Right = left.Value + width.Value, Y = top.Value, Bottom = top.Value + height.Value,
            Thickness = emu / 12700f
        };
        return ReadLineAnchor(line, anchors, FileShapeAddress.AnchorType.page, FileShapeAddress.AnchorType.page) == null
            ? null : line;
    }

    private static void AddFloatingLineGroups(ZipArchive archive, XElement body, Dictionary<int, FileShapeAddress> anchors,
        XDocument relationships, HashSet<string> ids, HashSet<string> drawingIds, Dictionary<string, byte[]> images)
    {
        var paragraphs = body.Elements().ToArray();
        var section = body.Element(W + "sectPr");
        var ordinal = 0;
        for (var i = paragraphs.Length - 1; i >= 0 && ordinal < MaxFigures; i--)
        {
            var paragraph = paragraphs[i];
            if (paragraph.Name != W + "p") continue;
            var properties = paragraph.Element(W + "pPr");
            var change = properties == null ? null : properties.Element(W + "sectPr");
            if (change != null) section = change;
            var pictures = paragraph.Elements(W + "r").Elements(W + "pict").Take(33).ToArray();
            if (pictures.Length == 0 || pictures.Length > 32) continue;
            var lines = pictures.Select(picture => ReadLine(picture, MarginLineOrder))
                .Where(line => line != null && (line.Left == line.Right) != (line.Y == line.Bottom) &&
                    line.Thickness >= .05f && line.Thickness <= 8 && ReadMarginAnchor(line, anchors) != null)
                .ToArray();
            if (lines.Length != 0)
            {
                var left = Math.Min(0, lines.Min(line => line.Left - (line.Left == line.Right ? line.Thickness / 2 : 0)));
                var right = lines.Max(line => line.Right + (line.Left == line.Right ? line.Thickness / 2 : 0));
                var top = lines.Min(line => line.Y - (line.Y == line.Bottom ? line.Thickness / 2 : 0));
                var bottom = lines.Max(line => line.Bottom + (line.Y == line.Bottom ? line.Thickness / 2 : 0));
                WriteLineGroup(archive, paragraph, relationships, ids, drawingIds, images, lines,
                    new RectangleF(left, top, right - left, bottom - top), ref ordinal, null);
                continue;
            }
            // A connector-only paragraph at the beginning of a new printed
            // section can keep the whole page canvas and its exact offsets.
            if (i == 0 || section == null || paragraph.Elements().Any(n => n.Name != W + "r" && n.Name != W + "pPr") ||
                paragraph.Elements(W + "r").Elements().Any(n => n.Name != W + "rPr" && n.Name != W + "pict" &&
                    (n.Name != W + "t" || !String.IsNullOrWhiteSpace(n.Value)))) continue;
            var previous = paragraphs[i - 1].Element(W + "pPr");
            var priorSection = previous == null ? null : previous.Element(W + "sectPr");
            if (priorSection == null || (string)priorSection.Elements(W + "type").Attributes(W + "val").FirstOrDefault()
                != "nextPage") continue;
            lines = pictures.Select(picture => ReadPageConnector(picture, anchors)).ToArray();
            var size = section.Element(W + "pgSz");
            var page = new Size(WordTwips(size, "w", 0), WordTwips(size, "h", 0));
            var canvas = new RectangleF(0, 0, page.Width / 20f, page.Height / 20f);
            if (lines.Any(line => line == null || line.Thickness < .05f || line.Thickness > 8 ||
                line.Left < 0 || line.Y < 0 || line.Right > canvas.Right || line.Bottom > canvas.Bottom)) continue;
            WriteLineGroup(archive, paragraph, relationships, ids, drawingIds, images, lines, canvas, ref ordinal, page);
        }
    }

    private static void WriteLineGroup(ZipArchive archive, XElement paragraph, XDocument relationships,
        HashSet<string> ids, HashSet<string> drawingIds, Dictionary<string, byte[]> images, LineStroke[] lines,
        RectangleF bounds, ref int ordinal, Size? pageTwips)
    {
        if (bounds.Width <= 0 || bounds.Width > 1000 || bounds.Height <= 0 || bounds.Height > 1000 ||
            images.Values.Sum(data => (long)data.Length) > MaxFigureBytes) return;
        // Align the cropped canvas to the bitmap grid so that even the
        // thinnest stroke has the same ink coverage as at its original offset.
        var left = (float)Math.Floor(bounds.Left * PixelsPerPoint) / PixelsPerPoint;
        var top = (float)Math.Floor(bounds.Top * PixelsPerPoint) / PixelsPerPoint;
        var width = (int)Math.Ceiling((bounds.Right - left) * PixelsPerPoint);
        var height = (int)Math.Ceiling((bounds.Bottom - top) * PixelsPerPoint);
        using (var bitmap = new Bitmap(width, height, PixelFormat.Format32bppArgb))
        {
            foreach (var line in lines)
                if (line.Left == line.Right)
                    PaintAxisRule(bitmap, line.Y - top, line.Bottom - top, line.Left - left, line.Thickness, true);
                else PaintAxisRule(bitmap, line.Left - left, line.Right - left, line.Y - top, line.Thickness);
            InsertRuleImage(archive, paragraph, relationships, ids, drawingIds, images,
                pageTwips.HasValue ? "rIdHomeLibreLinePage" : "rIdHomeLibreFloatingLineGroup",
                ref ordinal, bitmap, pageTwips);
        }
        foreach (var line in lines) line.Picture.Remove();
    }

    internal static void Reflow(string path, WordDocument document)
    {
        // Keep the replacement on the same volume. The output may already have
        // a long cache name, and the cache can remove leftovers after a crash.
        var prepared = Path.Combine(Path.GetDirectoryName(path), "homelib-.pending-" +
            System.Diagnostics.Process.GetCurrentProcess().Id.ToString(CultureInfo.InvariantCulture) +
            "-" + Path.GetRandomFileName());
        var ownsPrepared = false;
        try
        {
            if (new FileInfo(path).Length <= HomeLibDoc.MaximumBytes - 12 * 1024 * 1024 &&
                WriteReflowed(path, prepared, document, out ownsPrepared)) File.Replace(prepared, path, null);
        }
        catch (Exception error)
        {
            if (!(error is IOException || error is InvalidDataException || error is XmlException ||
                  error is ArgumentException || error is ExternalException || error is UnauthorizedAccessException)) throw;
            // Keep the original staging DOCX when a preview cannot be made.
            Console.Error.WriteLine("DOC figure preview: " + error.Message);
        }
        finally
        {
            if (ownsPrepared)
                try { File.Delete(prepared); } catch (IOException) { } catch (UnauthorizedAccessException) { }
        }
    }

    private static bool WriteReflowed(string source, string destination, WordDocument original, out bool ownsDestination)
    {
        ownsDestination = false;
        using (var input = File.OpenRead(source))
        using (var archive = new ZipArchive(input, ZipArchiveMode.Read))
        {
            const string documentPath = "word/document.xml", typesPath = "[Content_Types].xml";
            const string relsPath = "word/_rels/document.xml.rels";
            bool freeform, emptyPictures, paragraphRules, marginRules, compoundFigures, groupedLines;
            InspectDrawings(archive.GetEntry(documentPath), out freeform, out emptyPictures, out paragraphRules,
                out marginRules, out compoundFigures, out groupedLines);
            if (!freeform && !emptyPictures && !paragraphRules && !marginRules && !compoundFigures && !groupedLines) return false;
            var doc = Read(archive, documentPath);
            var body = doc == null ? null : doc.Root.Element(W + "body");
            if (body == null) return false;
            var styles = Read(archive, "word/styles.xml");
            var normal = styles == null ? null : styles.Root.Elements(W + "style")
                .FirstOrDefault(s => (string)s.Attribute(W + "styleId") == "Normal");
            var hasPlotStyle = freeform && normal != null && !normal.Descendants(W + "spacing").Any() &&
                normal.Descendants(W + "sz").Any(n => (string)n.Attribute(W + "val") == "24") &&
                normal.Descendants(W + "rFonts").Any(n => (string)n.Attribute(W + "ascii") == "Arial");
            if (!hasPlotStyle && !emptyPictures && !paragraphRules && !marginRules && !compoundFigures && !groupedLines) return false;
            var relationships = Read(archive, relsPath);
            var types = Read(archive, typesPath);
            if (relationships == null || types == null) return false;
            var ids = new HashSet<string>(relationships.Root.Elements().Select(n => (string)n.Attribute("Id")));
            var drawingIds = new HashSet<string>(doc.Descendants().Where(n => n.Name.LocalName == "docPr")
                .Select(n => (string)n.Attribute("id")));
            var paragraphs = body.Elements().ToArray();
            var count = 0;
            var totalBytes = 0;
            var images = new Dictionary<string, byte[]>();
            if (emptyPictures) AddHorizontalRules(archive, body, original, relationships, ids, drawingIds, images);
            var removedDuplicatePictures = emptyPictures && RemoveDuplicateInlinePictures(archive, body, original, relationships);
            var repairedGroupGeometry=groupedLines && RepairGroupDrawingGeometry(body,original);
            for (var start = 0; hasPlotStyle && count < MaxFigures && start < paragraphs.Length; start++)
            {
                var picts = new List<XElement>();
                string line;
                if (!paragraphs[start].Descendants(W + "pict").Any() ||
                    !ReadPlotParagraph(paragraphs[start], picts, out line) || picts.Count == 0) continue;
                var shapes = new List<Shape>();
                var labels = new List<string>();
                var end = start;
                try
                {
                    var stop = start;
                    var supported = true;
                    for (; stop < paragraphs.Length && stop < start + MaxParagraphs; stop++)
                    {
                        picts.Clear();
                        if (!ReadPlotParagraph(paragraphs[stop], picts, out line)) break;
                        labels.Add(line);
                        if (picts.Count == 0) continue;
                        end = stop + 1;
                        foreach (var pict in picts)
                        {
                            var shape = new Shape();
                            shapes.Add(shape);
                            if (ReadShape(pict, (stop - start) * BodyLineHeight, shape)) continue;
                            supported = false;
                            break;
                        }
                        if (!supported || shapes.Count > 128) break;
                    }
                    if (!supported || stop - start >= MaxParagraphs || stop < end) { start = end - 1; continue; }
                    Size size;
                    var image = Plot(shapes, labels.Take(end - start).ToList(), ref totalBytes, out size);
                    if (image == null) continue;
                    string id, path;
                    do
                    {
                        id = "rIdHomeLibreFigure" + (++count).ToString(CultureInfo.InvariantCulture);
                        path = "media/" + id + ".png";
                    }
                    while (ids.Contains(id) || drawingIds.Contains(count.ToString(CultureInfo.InvariantCulture)) ||
                           archive.GetEntry("word/" + path) != null);
                    images.Add("word/" + path, image);
                    relationships.Root.Add(new XElement(Rel + "Relationship", new XAttribute("Id", id),
                        new XAttribute("Type", R.NamespaceName + "/image"), new XAttribute("Target", path)));
                    paragraphs[start].AddBeforeSelf(ImageParagraph(id, count, size,
                        String.Join(", ", labels.Take(end - start).Where(s => s.Length == 1))));
                    for (var i = start; i < end; i++) paragraphs[i].Remove();
                    if (stop < paragraphs.Length && stop - end <= 2) RestoreLegendArrow(paragraphs[stop]);
                    start = end - 1;
                }
                finally { foreach (var shape in shapes) shape.Dispose(); }
            }
            var defaultRun=styles==null ? null : styles.Root.Elements(W+"docDefaults")
                .Elements(W+"rPrDefault").Elements(W+"rPr").FirstOrDefault();
            if (paragraphRules) AddParagraphRules(archive, body, original, normal, defaultRun, relationships, ids, drawingIds, images);
            if (marginRules || compoundFigures)
            {
                var anchors = ReadMarginAnchors(original);
                if (marginRules)
                {
                    AddMarginRules(archive, body, anchors, relationships, ids, drawingIds, images);
                    AddVerticalMarginRules(archive, body, anchors, relationships, ids, drawingIds, images);
                    AddFloatingLineGroups(archive, body, anchors, relationships, ids, drawingIds, images);
                }
                if (compoundFigures) AddCompoundFigures(archive,body,normal,defaultRun,anchors,relationships,ids,drawingIds,images);
            }
            if (images.Count == 0 && !removedDuplicatePictures && !repairedGroupGeometry) return false;
            if (images.Count > 0 && !types.Root.Elements(Types + "Default").Any(x => (string)x.Attribute("Extension") == "png"))
                types.Root.Add(new XElement(Types + "Default", new XAttribute("Extension", "png"), new XAttribute("ContentType", "image/png")));
            using (var file = new FileStream(destination, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                ownsDestination = true;
                using (var bounded = new BoundedDocOutput(file))
                using (var output = new ZipArchive(bounded, ZipArchiveMode.Create))
                {
                    foreach (var entry in archive.Entries)
                    {
                        if (entry.FullName == documentPath || entry.FullName == relsPath || entry.FullName == typesPath) continue;
                        using (var content = entry.Open())
                        using (var copy = output.CreateEntry(entry.FullName).Open())
                            content.CopyTo(copy);
                    }
                    foreach (var image in images)
                        using (var entry = output.CreateEntry(image.Key, CompressionLevel.NoCompression).Open())
                            entry.Write(image.Value, 0, image.Value.Length);
                    Save(output, documentPath, doc);
                    Save(output, relsPath, relationships);
                    Save(output, typesPath, types);
                }
            }
            return true;
        }
    }
}
