// Test-only JPEG XR source, generated through the installed Windows codec.
using System.IO;
using System.Windows.Media;
using System.Windows.Media.Imaging;
class XpsResourceFixture {
    [System.STAThread] static void Main(string[] args) {
        byte[] pixels=new byte[24*32*3];
        for(int i=0;i<pixels.Length;i+=3) { pixels[i]=176;pixels[i+1]=80;pixels[i+2]=32; }
        var bitmap=BitmapSource.Create(24,32,96,96,PixelFormats.Bgr24,null,pixels,24*3);
        var encoder=new WmpBitmapEncoder();encoder.Lossless=true;
        encoder.Frames.Add(BitmapFrame.Create(bitmap));
        using(var file=new FileStream(args[0],FileMode.CreateNew))encoder.Save(file);
    }
}
