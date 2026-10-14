import MLX

public enum WhisperMLXMemory {
    /// MLX keeps freed GPU buffers for reuse; after the model is released,
    /// hand them back to the system.
    public static func releaseCachedBuffers() {
        Memory.clearCache()
    }
}
