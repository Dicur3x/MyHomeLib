using System;
using System.IO;
using System.Text;
using b2xtranslator.txt;

internal static class Program
{
    private const long MaxInputBytes = 64L * 1024 * 1024;
    private const int MaxCharacters = 16 * 1024 * 1024;

    private static int Main(string[] args)
    {
        if (args.Length != 2)
            return 2;

        try
        {
            var source = new FileInfo(args[0]);
            string destination = Path.GetFullPath(args[1]);
            if (source.Length < 512 || source.Length > MaxInputBytes ||
                string.Equals(source.FullName, destination, StringComparison.OrdinalIgnoreCase))
                return 2;

            string text = DocTextExtractor.ExtractTextFromFile(source.FullName, false);
            if (string.IsNullOrWhiteSpace(text) || text.Length > MaxCharacters)
                return 1;

            using (var file = new FileStream(destination, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            using (var writer = new StreamWriter(file, new UTF8Encoding(false)))
                writer.Write(text);
            return 0;
        }
        catch (Exception error)
        {
            Console.Error.WriteLine(error.Message);
            return 1;
        }
    }
}
