using System.Text;

namespace DoNotType.Core;

/// <summary>Writes a complete, flushed sibling before replacing user-owned text.</summary>
public static class AtomicFile
{
    public static void ReplaceText(string path, string contents)
    {
        var directory = Path.GetDirectoryName(path);
        if (string.IsNullOrEmpty(directory))
        {
            throw new ArgumentException("A durable file needs a parent directory.", nameof(path));
        }

        Directory.CreateDirectory(directory);
        // Unique across processes: two accidentally running tray instances may race, but neither
        // can truncate the other's temporary file or leave malformed JSON behind.
        var temporary = $"{path}.{Environment.ProcessId}.{Guid.NewGuid():N}.tmp";
        try
        {
            using (var stream = new FileStream(
                temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None,
                bufferSize: 4096, FileOptions.WriteThrough))
            {
                using (var writer = new StreamWriter(
                    stream, new UTF8Encoding(encoderShouldEmitUTF8Identifier: false),
                    bufferSize: 1024, leaveOpen: true))
                {
                    writer.Write(contents);
                    writer.Flush();
                }
                stream.Flush(flushToDisk: true);
            }
            File.Move(temporary, path, overwrite: true);
        }
        catch
        {
            try { File.Delete(temporary); } catch (Exception) { }
            throw;
        }
    }
}
