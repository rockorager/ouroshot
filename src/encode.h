#include <stdint.h>
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
int shot_png(const char *path, const uint8_t *bgra, int width, int height);
int shot_png_fd(int fd, const uint8_t *bgra, int width, int height);
ShotVideo *shot_video_open(const char *path, int width, int height, int fps,
                          const char *encoder, const char *device, ShotDma *dma, int rgba);
int shot_video_frame(ShotVideo *video, const uint8_t *bgra, int stride, int64_t pts_us);
int shot_video_dma_frame(ShotVideo *video, ShotDma *dma, int crop_x, int crop_y, int64_t pts_us);
int shot_video_repeat(ShotVideo *video, int64_t pts_us);
int shot_video_close(ShotVideo *video);
void shot_signals(void);
int shot_stopping(void);
