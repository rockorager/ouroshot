#include <stdint.h>
enum ShotSourceEncoding { SHOT_SOURCE_UNKNOWN, SHOT_SOURCE_SRGB, SHOT_SOURCE_GAMMA22 };
// Source primaries for the two known encodings are sRGB/BT.709. Protocols and
// FourCC do not supply this information; the desktop operator selects it.
int shot_source_encoding(const char *name);
typedef struct ShotVideo ShotVideo;
typedef struct ShotDma ShotDma;
typedef struct ShotDmaInfo {
    int fd, width, height, stride;
    uint32_t format;
    uint64_t modifier;
} ShotDmaInfo;
ShotDma *shot_dma_create(const char *device, uint64_t compositor_device, int width, int height);
ShotDmaInfo shot_dma_info(ShotDma *buffer);
void shot_dma_destroy(ShotDma *buffer);
// PNG takes straight BGRA, not Wayland premultiplied ARGB. Capture normalization
// supplies opaque pixels (associated RGB flattened against black).
int shot_png(const char *path, const uint8_t *bgra, int width, int height, int source_encoding);
int shot_png_fd(int fd, const uint8_t *bgra, int width, int height, int source_encoding);
// Video takes opaque RGB0/BGR0; its unused fourth byte is never alpha.
ShotVideo *shot_video_open(const char *path, int width, int height, int fps,
                          const char *encoder, const char *device, ShotDma *dma, int rgba, int source_encoding);
int shot_video_frame(ShotVideo *video, const uint8_t *bgra, int stride, int64_t pts_us);
int shot_video_dma_frame(ShotVideo *video, ShotDma *dma, int crop_x, int crop_y, int64_t pts_us);
int shot_video_repeat(ShotVideo *video, int64_t pts_us);
int shot_video_close(ShotVideo *video);
void shot_signals(void);
int shot_stopping(void);
