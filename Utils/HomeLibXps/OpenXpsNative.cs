// Copyright (c) 2026 MyHomeLib contributors. MIT; see ../../LICENSE.
// Windows 8+ XPS OM bridge. Interface order follows the Windows SDK; unused
// methods occupy their ABI slots and are never called. No package is saved back.
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using STATSTG = System.Runtime.InteropServices.ComTypes.STATSTG;

internal static class OpenXpsNative
{
    internal sealed class ApiUnavailableException : IOException
    {
        internal ApiUnavailableException() : base("OpenXPS requires the Windows 8 or newer XPS Document API.") { }
    }
    [ComImport,Guid("0a91b617-d612-4181-bf7c-be5824e9cc8f"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IXpsOMObjectFactory1
    {
        [PreserveSig] int CreatePackage();
        [PreserveSig] int CreatePackageFromFile();
        [PreserveSig] int CreatePackageFromStream();
        [PreserveSig] int CreateStoryFragmentsResource();
        [PreserveSig] int CreateDocumentStructureResource();
        [PreserveSig] int CreateSignatureBlockResource();
        [PreserveSig] int CreateRemoteDictionaryResource();
        [PreserveSig] int CreateRemoteDictionaryResourceFromStream();
        [PreserveSig] int CreatePartResources();
        [PreserveSig] int CreateDocumentSequence();
        [PreserveSig] int CreateDocument();
        [PreserveSig] int CreatePageReference();
        [PreserveSig] int CreatePage();
        [PreserveSig] int CreatePageFromStream();
        [PreserveSig] int CreateCanvas();
        [PreserveSig] int CreateGlyphs();
        [PreserveSig] int CreatePath();
        [PreserveSig] int CreateGeometry();
        [PreserveSig] int CreateGeometryFigure();
        [PreserveSig] int CreateMatrixTransform();
        [PreserveSig] int CreateSolidColorBrush();
        [PreserveSig] int CreateColorProfileResource();
        [PreserveSig] int CreateImageBrush();
        [PreserveSig] int CreateVisualBrush();
        [PreserveSig] int CreateImageResource();
        [PreserveSig] int CreatePrintTicketResource();
        [PreserveSig] int CreateFontResource();
        [PreserveSig] int CreateGradientStop();
        [PreserveSig] int CreateLinearGradientBrush();
        [PreserveSig] int CreateRadialGradientBrush();
        [PreserveSig] int CreateCoreProperties();
        [PreserveSig] int CreateDictionary();
        [PreserveSig] int CreatePartUriCollection();
        [PreserveSig] int CreatePackageWriterOnFile();
        [PreserveSig] int CreatePackageWriterOnStream();
        [PreserveSig] int CreatePartUri();
        [PreserveSig] int CreateReadOnlyStreamOnFile([MarshalAs(UnmanagedType.LPWStr)] string path,out IStream stream);
        [PreserveSig] int GetDocumentTypeFromFile();
        [PreserveSig] int GetDocumentTypeFromStream();
        [PreserveSig] int ConvertHDPhotoToJpegXR();
        [PreserveSig] int ConvertJpegXRToHDPhoto(IXpsOMImageResource resource);
        [PreserveSig] int CreatePackageWriterOnFile1();
        [PreserveSig] int CreatePackageWriterOnStream1();
        [PreserveSig] int CreatePackage1();
        [PreserveSig] int CreatePackageFromStream1(IStream stream,[MarshalAs(UnmanagedType.Bool)] bool reuse,out IXpsOMPackage1 package);
        [PreserveSig] int CreatePackageFromFile1();
        [PreserveSig] int CreatePage1();
        [PreserveSig] int CreatePageFromStream1();
        [PreserveSig] int CreateRemoteDictionaryResourceFromStream1();
    }

    [ComImport,Guid("95a9435e-12bb-461b-8e7f-c6adb04cd96a"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IXpsOMPackage1
    {
        [PreserveSig] int GetDocumentSequence(out IXpsOMDocumentSequence sequence);
        [PreserveSig] int SetDocumentSequence();
        [PreserveSig] int GetCoreProperties();
        [PreserveSig] int SetCoreProperties();
        [PreserveSig] int GetDiscardControlPartName();
        [PreserveSig] int SetDiscardControlPartName();
        [PreserveSig] int GetThumbnailResource();
        [PreserveSig] int SetThumbnailResource();
        [PreserveSig] int WriteToFile();
        [PreserveSig] int WriteToStream();
        [PreserveSig] int GetDocumentType();
        [PreserveSig] int WriteToFile1();
        [PreserveSig] int WriteToStream1(IStream stream,[MarshalAs(UnmanagedType.Bool)] bool optimize,int kind);
    }

    [ComImport,Guid("56492EB4-D8D5-425e-8256-4C2B64AD0264"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IXpsOMDocumentSequence
    {
        [PreserveSig] int GetPartName();
        [PreserveSig] int SetPartName();
        [PreserveSig] int GetOwner();
        [PreserveSig] int GetDocuments(out IXpsOMDocumentCollection documents);
        [PreserveSig] int GetPrintTicketResource();
        [PreserveSig] int SetPrintTicketResource();
    }

    [ComImport,Guid("D1C87F0D-E947-4754-8A25-971478F7E83E"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IXpsOMDocumentCollection
    {
        [PreserveSig] int GetCount(out uint count);
        [PreserveSig] int GetAt(uint index,out IXpsOMDocument document);
        [PreserveSig] int InsertAt();
        [PreserveSig] int RemoveAt(uint index);
        [PreserveSig] int SetAt();
        [PreserveSig] int Append();
    }

    [ComImport,Guid("2C2C94CB-AC5F-4254-8EE9-23948309D9F0"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IXpsOMDocument
    {
        [PreserveSig] int GetPartName();
        [PreserveSig] int SetPartName();
        [PreserveSig] int GetOwner();
        [PreserveSig] int GetPageReferences(out IXpsOMPageReferenceCollection pages);
        [PreserveSig] int GetPrintTicketResource();
        [PreserveSig] int SetPrintTicketResource();
        [PreserveSig] int GetDocumentStructureResource();
        [PreserveSig] int SetDocumentStructureResource();
        [PreserveSig] int GetSignatureBlockResources();
        [PreserveSig] int Clone();
    }

    [ComImport,Guid("CA16BA4D-E7B9-45C5-958B-F98022473745"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IXpsOMPageReferenceCollection
    {
        [PreserveSig] int GetCount(out uint count);
        [PreserveSig] int GetAt(uint index,out IXpsOMPageReference page);
        [PreserveSig] int InsertAt();
        [PreserveSig] int RemoveAt(uint index);
        [PreserveSig] int SetAt();
        [PreserveSig] int Append();
    }

    [ComImport,Guid("ED360180-6F92-4998-890D-2F208531A0A0"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IXpsOMPageReference
    {
        [PreserveSig] int GetOwner();
        [PreserveSig] int GetPage();
        [PreserveSig] int SetPage();
        [PreserveSig] int DiscardPage();
        [PreserveSig] int IsPageLoaded();
        [PreserveSig] int GetAdvisoryPageDimensions();
        [PreserveSig] int SetAdvisoryPageDimensions();
        [PreserveSig] int GetStoryFragmentsResource();
        [PreserveSig] int SetStoryFragmentsResource();
        [PreserveSig] int GetPrintTicketResource();
        [PreserveSig] int SetPrintTicketResource();
        [PreserveSig] int GetThumbnailResource();
        [PreserveSig] int SetThumbnailResource();
        [PreserveSig] int CollectLinkTargets();
        [PreserveSig] int CollectPartResources(out IXpsOMPartResources resources);
        [PreserveSig] int HasRestrictedFonts();
        [PreserveSig] int Clone();
    }

    [ComImport,Guid("f4cf7729-4864-4275-99b3-a8717163ecaf"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IXpsOMPartResources
    {
        [PreserveSig] int GetFontResources();
        [PreserveSig] int GetImageResources(out IXpsOMImageResourceCollection images);
        [PreserveSig] int GetColorProfileResources();
        [PreserveSig] int GetRemoteDictionaryResources();
    }

    [ComImport,Guid("7A4A1A71-9CDE-4B71-B33F-62DE843EABFE"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IXpsOMImageResourceCollection
    {
        [PreserveSig] int GetCount(out uint count);
        [PreserveSig] int GetAt(uint index,out IXpsOMImageResource image);
        [PreserveSig] int InsertAt();
        [PreserveSig] int RemoveAt();
        [PreserveSig] int SetAt();
        [PreserveSig] int Append();
        [PreserveSig] int GetByPartName();
    }

    [ComImport,Guid("3db8417d-ae50-485e-9a44-d7758f78a23f"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IXpsOMImageResource
    {
        [PreserveSig] int GetPartName();
        [PreserveSig] int SetPartName();
        [PreserveSig] int GetStream();
        [PreserveSig] int SetContent();
        [PreserveSig] int GetImageType(out int kind);
    }

    [DllImport("ole32.dll",ExactSpelling=true)]
    private static extern int CoCreateInstance(ref Guid clsid,IntPtr outer,uint context,ref Guid iid,out IntPtr result);

    private static void Release(object value)
    {
        if (value != null && Marshal.IsComObject(value)) Marshal.FinalReleaseComObject(value);
    }

    // The native writer only receives this bounded memory stream. It cannot
    // choose a filename or replace the input, and the parent job limits memory.
    [ComVisible(true),ClassInterface(ClassInterfaceType.None)]
    private sealed class PackageStream : IStream
    {
        internal readonly MemoryStream Data = new MemoryStream();
        private const long Limit = 256L*1024*1024;
        public void Read(byte[] buffer,int count,IntPtr actual)
        {
            int read=Data.Read(buffer,0,count); if(actual!=IntPtr.Zero) Marshal.WriteInt32(actual,read);
        }
        public void Write(byte[] buffer,int count,IntPtr actual)
        {
            if(count<0 || Data.Position>Limit-count) throw new IOException("Normalized XPS exceeds 256 MB.");
            Data.Write(buffer,0,count); if(actual!=IntPtr.Zero) Marshal.WriteInt32(actual,count);
        }
        public void Seek(long move,int origin,IntPtr actual)
        {
            long position=Data.Seek(move,(SeekOrigin)origin);
            if(position<0 || position>Limit) throw new IOException("Invalid normalized XPS position.");
            if(actual!=IntPtr.Zero) Marshal.WriteInt64(actual,position);
        }
        public void SetSize(long size)
        {
            if(size<0 || size>Limit) throw new IOException("Normalized XPS exceeds 256 MB."); Data.SetLength(size);
        }
        public void Commit(int flags) { Data.Flush(); }
        public void Revert() { throw new NotSupportedException(); }
        public void LockRegion(long at,long count,int kind) { throw new NotSupportedException(); }
        public void UnlockRegion(long at,long count,int kind) { throw new NotSupportedException(); }
        public void Stat(out STATSTG stat,int flags)
        {
            stat=new STATSTG();stat.type=2;stat.cbSize=Data.Length;stat.grfMode=2;
        }
        public void Clone(out IStream copy) { throw new NotSupportedException(); }
        public void CopyTo(IStream target,long size,IntPtr read,IntPtr written) { throw new NotSupportedException(); }
    }

    private static void FirstPageOnly(IXpsOMPackage1 package)
    {
        IXpsOMDocumentSequence sequence=null; IXpsOMDocumentCollection documents=null;
        try
        {
            Marshal.ThrowExceptionForHR(package.GetDocumentSequence(out sequence));
            Marshal.ThrowExceptionForHR(sequence.GetDocuments(out documents));
            uint count; Marshal.ThrowExceptionForHR(documents.GetCount(out count));
            if(count==0 || count>5000) throw new IOException("Invalid OpenXPS document count.");
            while(count>0)
            {
                IXpsOMDocument document=null;IXpsOMPageReferenceCollection pages=null;
                try
                {
                    Marshal.ThrowExceptionForHR(documents.GetAt(0,out document));
                    Marshal.ThrowExceptionForHR(document.GetPageReferences(out pages));
                    uint n;Marshal.ThrowExceptionForHR(pages.GetCount(out n));
                    if(n>5000) throw new IOException("Too many OpenXPS pages.");
                    if(n>0)
                    {
                        while(n>1) Marshal.ThrowExceptionForHR(pages.RemoveAt(--n));
                        while(count>1) Marshal.ThrowExceptionForHR(documents.RemoveAt(--count));
                        return;
                    }
                }
                finally { Release(pages);Release(document); }
                Marshal.ThrowExceptionForHR(documents.RemoveAt(0));count--;
            }
            throw new IOException("OpenXPS has no pages.");
        }
        finally { Release(documents);Release(sequence); }
    }

    private static void PrepareImages(IXpsOMObjectFactory1 factory,IXpsOMPackage1 package)
    {
        IXpsOMDocumentSequence sequence=null; IXpsOMDocumentCollection documents=null;
        try
        {
            Marshal.ThrowExceptionForHR(package.GetDocumentSequence(out sequence));
            Marshal.ThrowExceptionForHR(sequence.GetDocuments(out documents));
            uint count; Marshal.ThrowExceptionForHR(documents.GetCount(out count));
            if(count==0 || count>5000) throw new IOException("Invalid OpenXPS document count.");
            uint pageCount=0; int resourceCount=0;
            for(uint d=0;d<count;d++)
            {
                IXpsOMDocument document=null; IXpsOMPageReferenceCollection pages=null;
                try
                {
                    Marshal.ThrowExceptionForHR(documents.GetAt(d,out document));
                    Marshal.ThrowExceptionForHR(document.GetPageReferences(out pages));
                    uint length; Marshal.ThrowExceptionForHR(pages.GetCount(out length));
                    if(length>5000-pageCount) throw new IOException("Too many OpenXPS pages."); pageCount+=length;
                    for(uint p=0;p<length;p++)
                    {
                        IXpsOMPageReference page=null; IXpsOMPartResources resources=null;
                        IXpsOMImageResourceCollection images=null;
                        try
                        {
                            Marshal.ThrowExceptionForHR(pages.GetAt(p,out page));
                            Marshal.ThrowExceptionForHR(page.CollectPartResources(out resources));
                            Marshal.ThrowExceptionForHR(resources.GetImageResources(out images));
                            uint n; Marshal.ThrowExceptionForHR(images.GetCount(out n));
                            if(n>20000) throw new IOException("Too many OpenXPS image resources.");
                            for(uint i=0;i<n;i++)
                            {
                                IXpsOMImageResource image=null;
                                try
                                {
                                    if(++resourceCount>100000) throw new IOException("Too many OpenXPS resource references.");
                                    Marshal.ThrowExceptionForHR(images.GetAt(i,out image));
                                    int kind; Marshal.ThrowExceptionForHR(image.GetImageType(out kind));
                                    // OpenXPS JPEG XR becomes the equivalent Windows HD Photo
                                    // resource through the Windows conversion API.
                                    if(kind==5) Marshal.ThrowExceptionForHR(factory.ConvertJpegXRToHDPhoto(image));
                                }
                                finally { Release(image); }
                            }
                        }
                        finally { Release(images);Release(resources);Release(page); }
                    }
                }
                finally { Release(pages);Release(document); }
            }
            if(pageCount==0) throw new IOException("OpenXPS has no pages.");
        }
        finally { Release(documents);Release(sequence); }
    }

    internal static MemoryStream Normalize(string source,bool firstPageOnly)
    {
        IXpsOMObjectFactory1 factory=null; IXpsOMPackage1 package=null; IStream input=null;
        var output=new PackageStream(); bool ready=false;
        try
        {
            var clsid=new Guid("E974D26D-3D9B-4D47-88CC-3872F2DC3585");
            var iid=new Guid("0a91b617-d612-4181-bf7c-be5824e9cc8f"); IntPtr pointer;
            int result=CoCreateInstance(ref clsid,IntPtr.Zero,1,ref iid,out pointer);
            if(result<0) throw new ApiUnavailableException();
            try { factory=(IXpsOMObjectFactory1)Marshal.GetObjectForIUnknown(pointer); }
            finally { Marshal.Release(pointer); }
            Marshal.ThrowExceptionForHR(factory.CreateReadOnlyStreamOnFile(source,out input));
            Marshal.ThrowExceptionForHR(factory.CreatePackageFromStream1(input,true,out package));
            if(firstPageOnly) FirstPageOnly(package);
            PrepareImages(factory,package);
            Marshal.ThrowExceptionForHR(package.WriteToStream1(output,true,2));
            if(output.Data.Length==0) throw new IOException("Empty normalized XPS.");
            output.Data.Position=0; ready=true;return output.Data;
        }
        finally
        {
            Release(package);Release(input);Release(factory);
            if(!ready) output.Data.Dispose();
        }
    }
}
