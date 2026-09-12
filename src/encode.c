#include "encode.h"
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <unistd.h>
#include <gbm.h>
#include <drm_fourcc.h>
#include <va/va.h>
#include <png.h>
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/opt.h>
#include <libavutil/hwcontext.h>
#include <libavutil/hwcontext_drm.h>
#include <libavutil/hwcontext_vaapi.h>
#include <libavfilter/avfilter.h>
#include <libavfilter/buffersrc.h>
#include <libavfilter/buffersink.h>
#include <libswscale/swscale.h>

static volatile sig_atomic_t stopping;
static void stop(int sig) { (void)sig; stopping = 1; }
void shot_signals(void) {
    struct sigaction sa = {0};
    sa.sa_handler = stop;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);
    signal(SIGPIPE, SIG_IGN);
}
int shot_stopping(void) { return stopping; }

int shot_source_encoding(const char *name) {
    if (!strcmp(name, "unknown")) return SHOT_SOURCE_UNKNOWN;
    if (!strcmp(name, "srgb")) return SHOT_SOURCE_SRGB;
    if (!strcmp(name, "gamma22")) return SHOT_SOURCE_GAMMA22;
    return -1;
}
static void gamma22_lut(uint8_t lut[256]) {
    for (int i = 0; i < 256; i++) {
        double linear = pow(i / 255.0, 2.2);
        double srgb = linear <= 0.0031308 ? 12.92 * linear : 1.055 * pow(linear, 1.0 / 2.4) - 0.055;
        lut[i] = (uint8_t)floor(srgb * 255.0 + 0.5);
    }
}
// Straight RGB only: alpha is linear coverage, never a transfer-encoded channel.
// Do not mutate capture storage: it is also the untagged frozen preview source.
static void convert_rgb(uint8_t *dst, const uint8_t *src, int width, const uint8_t lut[256]) {
    for (int x = 0; x < width; x++) {
        for (int c = 0; c < 3; c++) dst[x*4+c] = lut[src[x*4+c]];
        dst[x*4+3] = src[x*4+3];
    }
}

// Takes ownership of fd, including on error. The service creates it relative
// to a verified private directory; it never reopens a caller-supplied path.
// Unknown sources retain their bytes and have no color-space declaration.
int shot_png_fd(int fd, const uint8_t *bgra, int width, int height, int source_encoding) {
    FILE *file = fdopen(fd, "wb");
    if (!file) { close(fd); return -1; }
    uint8_t lut[256];
    uint8_t *row = NULL;
    if (source_encoding == SHOT_SOURCE_GAMMA22) {
        gamma22_lut(lut);
        row = malloc((size_t)width * 4);
        if (!row) { fclose(file); return -1; }
    }
    png_structp png = png_create_write_struct(PNG_LIBPNG_VER_STRING, NULL, NULL, NULL);
    png_infop info = png ? png_create_info_struct(png) : NULL;
    int ok = 0;
    if (png && info && !setjmp(png_jmpbuf(png))) {
        png_init_io(png, file);
        png_set_IHDR(png, info, width, height, 8, PNG_COLOR_TYPE_RGBA,
                     PNG_INTERLACE_NONE, PNG_COMPRESSION_TYPE_DEFAULT, PNG_FILTER_TYPE_DEFAULT);
        if (source_encoding != SHOT_SOURCE_UNKNOWN) png_set_sRGB(png, info, PNG_sRGB_INTENT_RELATIVE);
        png_set_bgr(png);
        png_write_info(png, info);
        for (int y = 0; y < height; y++) {
            const uint8_t *src = bgra + (size_t)y * width * 4;
            if (row) convert_rgb(row, src, width, lut);
            png_write_row(png, row ? row : src);
        }
        png_write_end(png, info);
        ok = 1;
    }
    png_destroy_write_struct(&png, &info);
    free(row);
    if (fclose(file)) ok = 0;
    return ok ? 0 : -1;
}

int shot_png(const char *path, const uint8_t *bgra, int width, int height, int source_encoding) {
    int stream = strcmp(path, "-") == 0;
    int fd = stream ? dup(STDOUT_FILENO) : open(path, O_WRONLY|O_CREAT|O_EXCL|O_CLOEXEC, 0600);
    if (fd < 0) { perror(path); return -1; }
    int result = shot_png_fd(fd, bgra, width, height, source_encoding);
    if (result && !stream) unlink(path);
    return result;
}

struct ShotDma {
    struct gbm_device *gbm;
    struct gbm_bo *bo;
    int drm_fd;
    ShotDmaInfo info;
    size_t size;
    char device[64];
};
void shot_dma_destroy(ShotDma *b) {
    if (!b) return;
    if (b->info.fd >= 0) close(b->info.fd);
    if (b->bo) gbm_bo_destroy(b->bo);
    if (b->gbm) gbm_device_destroy(b->gbm);
    if (b->drm_fd >= 0) close(b->drm_fd);
    free(b);
}
ShotDmaInfo shot_dma_info(ShotDma *b) { return b->info; }
ShotDma *shot_dma_create(const char *device, uint64_t compositor_device, int width, int height) {
    ShotDma *b = calloc(1, sizeof(*b));
    if (!b) return NULL;
    b->drm_fd = b->info.fd = -1;
    if (width <= 0 || height <= 0 || (uint64_t)width*height*4 > 512*1024*1024) goto fail;
    // Primary and render node dev_t values differ; compare their sysfs device.
    char expected[128];
    struct stat source, target, node;
    snprintf(expected,sizeof(expected),"/sys/dev/char/%u:%u/device",major(compositor_device),minor(compositor_device));
    if (stat(expected,&source)) goto fail;
    for (int index=128;index<192;index++) {
        if (device && *device) snprintf(b->device,sizeof(b->device),"%s",device);
        else snprintf(b->device,sizeof(b->device),"/dev/dri/renderD%d",index);
        if (!stat(b->device,&node)) {
            char actual[128];
            snprintf(actual,sizeof(actual),"/sys/dev/char/%u:%u/device",major(node.st_rdev),minor(node.st_rdev));
            if (!stat(actual,&target) && source.st_dev==target.st_dev && source.st_ino==target.st_ino) {
                b->drm_fd=open(b->device,O_RDWR|O_CLOEXEC);
                break;
            }
        }
        if (device && *device) break;
    }
    if (b->drm_fd < 0) goto fail;
    b->gbm=gbm_create_device(b->drm_fd);
    if (!b->gbm) goto fail;
    b->bo=gbm_bo_create(b->gbm,width,height,DRM_FORMAT_XRGB8888,GBM_BO_USE_RENDERING|GBM_BO_USE_LINEAR);
    if (!b->bo || gbm_bo_get_plane_count(b->bo)!=1 || gbm_bo_get_modifier(b->bo)!=DRM_FORMAT_MOD_LINEAR) goto fail;
    b->info=(ShotDmaInfo){gbm_bo_get_fd(b->bo),width,height,gbm_bo_get_stride(b->bo),DRM_FORMAT_XRGB8888,DRM_FORMAT_MOD_LINEAR};
    if (b->info.fd < 0) goto fail;
    off_t size=lseek(b->info.fd,0,SEEK_END);
    if (size < (off_t)b->info.stride*height) goto fail;
    b->size=size;
    return b;
fail:
    shot_dma_destroy(b);
    return NULL;
}

struct ShotVideo {
    AVFormatContext *format;
    AVCodecContext *codec;
    AVStream *stream;
    AVFrame *frame;
    struct SwsContext *sws;
    AVIOContext *io;
    AVBufferRef *device, *input_frames, *drm_device, *drm_frames;
    AVFilterGraph *graph;
    AVFilterContext *source, *sink;
    AVFrame *last;
    int fd, width, height, header;
    enum AVPixelFormat input_format;
    int source_encoding;
    uint8_t lut[256], *converted;
};
static int write_bytes(void *opaque, const uint8_t *buf, int size) {
    ShotVideo *v = opaque;
    int offset = 0;
    while (offset < size) {
        ssize_t n = write(v->fd, buf+offset, size-offset);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return AVERROR(errno ? errno : EIO);
        offset += n;
    }
    return size;
}
static int64_t seek_bytes(void *opaque, int64_t offset, int whence) {
    ShotVideo *v = opaque;
    if (whence == AVSEEK_SIZE) { struct stat st; return fstat(v->fd, &st) ? AVERROR(errno) : st.st_size; }
    off_t result = lseek(v->fd, offset, whence & ~AVSEEK_FORCE);
    return result < 0 ? AVERROR(errno) : result;
}
static void destroy(ShotVideo *v) {
    if (!v) return;
    free(v->converted);
    sws_freeContext(v->sws);
    av_frame_free(&v->frame);
    av_frame_free(&v->last);
    avcodec_free_context(&v->codec);
    avfilter_graph_free(&v->graph);
    av_buffer_unref(&v->input_frames);
    av_buffer_unref(&v->drm_frames);
    av_buffer_unref(&v->drm_device);
    av_buffer_unref(&v->device);
    avformat_free_context(v->format);
    if (v->io) { av_freep(&v->io->buffer); avio_context_free(&v->io); }
    if (v->fd >= 0) close(v->fd);
    free(v);
}

static int hardware_setup(ShotVideo *v, const char *device, ShotDma *dma) {
    if ((v->width&1) || (v->height&1)) return -1; // Keep odd-size padding lossless in the software path.
    const char *node=dma ? dma->device : (device && *device ? device : NULL);
    if (av_hwdevice_ctx_create(&v->device,AV_HWDEVICE_TYPE_VAAPI,node,NULL,0)<0) return -1;
    int width=dma ? dma->info.width : v->width;
    int height=dma ? dma->info.height : v->height;
    v->input_frames=av_hwframe_ctx_alloc(v->device);
    if (!v->input_frames) return -1;
    AVHWFramesContext *fc=(AVHWFramesContext*)v->input_frames->data;
    fc->format=AV_PIX_FMT_VAAPI; fc->sw_format=v->input_format;
    fc->width=width; fc->height=height;
    if (av_hwframe_ctx_init(v->input_frames)<0) return -1;
    if (dma) {
        if (av_hwdevice_ctx_create(&v->drm_device,AV_HWDEVICE_TYPE_DRM,node,NULL,0)<0) return -1;
        v->drm_frames=av_hwframe_ctx_alloc(v->drm_device);
        if (!v->drm_frames) return -1;
        AVHWFramesContext *dc=(AVHWFramesContext*)v->drm_frames->data;
        dc->format=AV_PIX_FMT_DRM_PRIME; dc->sw_format=AV_PIX_FMT_BGR0;
        dc->width=width; dc->height=height;
        if (av_hwframe_ctx_init(v->drm_frames)<0) return -1;
    }
    v->graph=avfilter_graph_alloc();
    if (!v->graph) return -1;
    v->graph->nb_threads=1;
    v->source=avfilter_graph_alloc_filter(v->graph,avfilter_get_by_name("buffer"),"capture");
    if (!v->source) return -1;
    AVBufferSrcParameters *params=av_buffersrc_parameters_alloc();
    if (!params) return -1;
    params->format=AV_PIX_FMT_VAAPI; params->width=width; params->height=height;
    params->time_base=(AVRational){1,1000000}; params->sample_aspect_ratio=(AVRational){1,1};
    params->color_space=AVCOL_SPC_RGB; params->color_range=AVCOL_RANGE_JPEG;
    params->hw_frames_ctx=v->input_frames;
    int err=av_buffersrc_parameters_set(v->source,params);
    av_free(params);
    if (err<0 || avfilter_init_str(v->source,NULL)<0) return -1;
    AVFilterContext *convert=NULL;
    char args[256];
    snprintf(args,sizeof(args),"w=%d:h=%d:format=nv12:out_color_matrix=bt709:out_range=limited%s",v->width,v->height,
             v->source_encoding == SHOT_SOURCE_UNKNOWN ? "" : ":out_color_primaries=bt709:out_color_transfer=iec61966-2-1");
    if (avfilter_graph_create_filter(&convert,avfilter_get_by_name("scale_vaapi"),"convert",args,NULL,v->graph)<0 ||
        avfilter_graph_create_filter(&v->sink,avfilter_get_by_name("buffersink"),"encode",NULL,NULL,v->graph)<0 ||
        avfilter_link(v->source,0,convert,0)<0 || avfilter_link(convert,0,v->sink,0)<0 ||
        avfilter_graph_config(v->graph,NULL)<0) return -1;
    return 0;
}

ShotVideo *shot_video_open(const char *path, int width, int height, int fps,
                          const char *encoder, const char *device, ShotDma *dma, int rgba, int source_encoding) {
    // VAAPI matrix conversion is not a gamma22 -> sRGB transfer conversion.
    if (dma && source_encoding == SHOT_SOURCE_GAMMA22) return NULL;
    av_log_set_level(AV_LOG_WARNING);
    ShotVideo *v = calloc(1, sizeof(*v));
    if (!v) return NULL;
    v->fd = -1; v->width = width; v->height = height;
    v->source_encoding = source_encoding;
    if (source_encoding == SHOT_SOURCE_GAMMA22) {
        gamma22_lut(v->lut);
        v->converted = malloc((size_t)width * height * 4);
        if (!v->converted) goto fail;
    }
    v->input_format=rgba ? AV_PIX_FMT_RGB0 : AV_PIX_FMT_BGR0;
    int hardware=strcmp(encoder,"software")!=0;
    if (hardware && hardware_setup(v,device,dma)<0) {
        destroy(v);
        if (strcmp(encoder,"auto")!=0 || dma) return NULL;
        fprintf(stderr,"ouroshot: VAAPI unavailable; using software encoding\n");
        return shot_video_open(path,width,height,fps,"software",device,NULL,rgba,source_encoding);
    }
    const AVCodec *codec = avcodec_find_encoder_by_name(hardware ? "h264_vaapi" : "libx264");
    if (!codec || avformat_alloc_output_context2(&v->format, NULL, NULL, path) < 0) goto fail;
    v->stream = avformat_new_stream(v->format, NULL);
    v->codec = avcodec_alloc_context3(codec);
    if (!v->stream || !v->codec) goto fail;
    v->codec->width = (width+1)&~1;
    v->codec->height = (height+1)&~1;
    v->codec->time_base = (AVRational){1,1000000};
    v->codec->framerate = (AVRational){fps,1};
    v->codec->pix_fmt = hardware ? AV_PIX_FMT_VAAPI : AV_PIX_FMT_YUV420P;
    if (hardware) v->codec->hw_frames_ctx=av_buffer_ref(av_buffersink_get_hw_frames_ctx(v->sink));
    v->codec->thread_count = 2;
    v->codec->max_b_frames = 0;
    v->codec->color_range = AVCOL_RANGE_MPEG;
    v->codec->colorspace = AVCOL_SPC_BT709;
    v->codec->color_primaries = source_encoding == SHOT_SOURCE_UNKNOWN ? AVCOL_PRI_UNSPECIFIED : AVCOL_PRI_BT709;
    v->codec->color_trc = source_encoding == SHOT_SOURCE_UNKNOWN ? AVCOL_TRC_UNSPECIFIED : AVCOL_TRC_IEC61966_2_1;
    if (v->format->oformat->flags & AVFMT_GLOBALHEADER) v->codec->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
    if (hardware) {
        av_opt_set(v->codec->priv_data,"rc_mode","CQP",0);
        av_opt_set(v->codec->priv_data,"qp","20",0);
        av_opt_set(v->codec->priv_data,"async_depth","2",0);
    } else {
        av_opt_set(v->codec->priv_data, "preset", "veryfast", 0);
        av_opt_set(v->codec->priv_data, "crf", "18", 0);
    }
    if (avcodec_open2(v->codec, codec, NULL) < 0) {
        if (hardware && !dma && strcmp(encoder,"auto")==0) {
            destroy(v);
            fprintf(stderr,"ouroshot: hardware encoder unavailable; using software encoding\n");
            return shot_video_open(path,width,height,fps,"software",device,NULL,rgba,source_encoding);
        }
        goto fail;
    }
    v->stream->time_base = v->codec->time_base;
    v->stream->avg_frame_rate = v->codec->framerate;
    if (avcodec_parameters_from_context(v->stream->codecpar, v->codec) < 0) goto fail;
    v->frame = av_frame_alloc();
    v->last = av_frame_alloc();
    if (!v->frame || !v->last) goto fail;
    if (!hardware) {
        v->frame->format = v->codec->pix_fmt;
        v->frame->width = v->codec->width; v->frame->height = v->codec->height;
        if (av_frame_get_buffer(v->frame, 32) < 0) goto fail;
        v->sws = sws_getContext(width,height,v->input_format,width,height,AV_PIX_FMT_YUV420P,SWS_BILINEAR,NULL,NULL,NULL);
        if (!v->sws) goto fail;
        const int *coeff = sws_getCoefficients(SWS_CS_ITU709);
        if (sws_setColorspaceDetails(v->sws,coeff,1,coeff,0,0,1<<16,1<<16) < 0) goto fail;
    }
    v->fd = open(path,O_RDWR|O_CREAT|O_EXCL|O_CLOEXEC,0600);
    if (v->fd < 0) { perror(path); goto fail; }
    unsigned char *buffer = av_malloc(32768);
    if (!buffer) goto file_fail;
    v->io = avio_alloc_context(buffer,32768,1,v,NULL,write_bytes,seek_bytes);
    if (!v->io) { av_free(buffer); goto file_fail; }
    v->format->pb = v->io;
    v->format->flags |= AVFMT_FLAG_CUSTOM_IO;
    if (avformat_write_header(v->format,NULL) < 0) goto file_fail;
    v->header = 1;
    fprintf(stderr,"ouroshot: encoder=%s input=%s\n",hardware ? "vaapi" : "software",dma ? "dma-buf" : "shm");
    return v;
file_fail:
    unlink(path);
fail:
    destroy(v);
    return NULL;
}
static int drain(ShotVideo *v) {
    AVPacket *packet = av_packet_alloc();
    if (!packet) return -1;
    int result = 0, err;
    while ((err = avcodec_receive_packet(v->codec, packet)) >= 0) {
        av_packet_rescale_ts(packet,v->codec->time_base,v->stream->time_base);
        packet->stream_index = v->stream->index;
        if (av_interleaved_write_frame(v->format,packet) < 0) { result = -1; break; }
        av_packet_unref(packet);
    }
    if (err != AVERROR(EAGAIN) && err != AVERROR_EOF && err < 0) result = -1;
    av_packet_free(&packet);
    return result;
}
static int hardware_frame(ShotVideo *v, AVFrame *input, int64_t pts_us) {
    input->pts=pts_us;
    input->color_range=AVCOL_RANGE_JPEG;
    input->colorspace=AVCOL_SPC_RGB;
    input->color_primaries=v->codec->color_primaries;
    input->color_trc=v->codec->color_trc;
    if (av_buffersrc_write_frame(v->source,input)<0) return -1;
    av_frame_unref(v->frame);
    if (av_buffersink_get_frame(v->sink,v->frame)<0) return -1;
    // VPP may release its input reference immediately after GPU submission.
    // Wait for conversion, NOT merely reference release, before the compositor
    // is allowed to overwrite the capture DMA-BUF. Encoder NV12 surfaces are
    // independent and remain owned by FFmpeg until encoding completes.
    AVHWDeviceContext *dc=(AVHWDeviceContext*)v->device->data;
    AVVAAPIDeviceContext *va=dc->hwctx;
    if (vaSyncSurface(va->display,(VASurfaceID)(uintptr_t)v->frame->data[3])!=VA_STATUS_SUCCESS) return -1;
    av_frame_unref(v->last);
    if (av_frame_ref(v->last,v->frame)<0) return -1;
    return shot_video_repeat(v,pts_us);
}
int shot_video_repeat(ShotVideo *v, int64_t pts_us) {
    if (!v->last->buf[0]) return -1;
    v->last->color_range=v->codec->color_range;
    v->last->colorspace=v->codec->colorspace;
    v->last->color_primaries=v->codec->color_primaries;
    v->last->color_trc=v->codec->color_trc;
    v->last->pts=pts_us;
    v->last->duration=1000000/v->codec->framerate.num;
    if (avcodec_send_frame(v->codec,v->last)<0) return -1;
    return drain(v);
}
static void free_drm(void *opaque, uint8_t *data) {
    (void)opaque;
    AVDRMFrameDescriptor *d=(AVDRMFrameDescriptor*)data;
    close(d->objects[0].fd);
    av_free(d);
}
int shot_video_dma_frame(ShotVideo *v, ShotDma *dma, int crop_x, int crop_y, int64_t pts_us) {
    int result=-1;
    AVFrame *drm=av_frame_alloc(), *mapped=av_frame_alloc();
    AVDRMFrameDescriptor *d=av_mallocz(sizeof(*d));
    if (!drm || !mapped || !d) { av_free(d); goto done; }
    int fd=fcntl(dma->info.fd,F_DUPFD_CLOEXEC,0);
    if (fd<0) { av_free(d); goto done; }
    d->nb_objects=1; d->objects[0]=(AVDRMObjectDescriptor){fd,dma->size,dma->info.modifier};
    d->nb_layers=1; d->layers[0].format=dma->info.format; d->layers[0].nb_planes=1;
    d->layers[0].planes[0]=(AVDRMPlaneDescriptor){0,0,dma->info.stride};
    drm->buf[0]=av_buffer_create((uint8_t*)d,sizeof(*d),free_drm,NULL,0);
    if (!drm->buf[0]) { free_drm(NULL,(uint8_t*)d); goto done; }
    drm->data[0]=(uint8_t*)d; drm->format=AV_PIX_FMT_DRM_PRIME;
    drm->width=dma->info.width; drm->height=dma->info.height;
    drm->hw_frames_ctx=av_buffer_ref(v->drm_frames);
    mapped->format=AV_PIX_FMT_VAAPI; mapped->hw_frames_ctx=av_buffer_ref(v->input_frames);
    if (av_hwframe_map(mapped,drm,AV_HWFRAME_MAP_READ|AV_HWFRAME_MAP_DIRECT)<0) goto done;
    mapped->crop_left=crop_x; mapped->crop_top=crop_y;
    mapped->crop_right=dma->info.width-crop_x-v->width;
    mapped->crop_bottom=dma->info.height-crop_y-v->height;
    result=hardware_frame(v,mapped,pts_us);
done:
    av_frame_free(&mapped); av_frame_free(&drm);
    return result;
}
int shot_video_frame(ShotVideo *v, const uint8_t *bgra, int row_stride, int64_t pts_us) {
    if (v->converted) {
        for (int y = 0; y < v->height; y++)
            convert_rgb(v->converted + (size_t)y * v->width * 4, bgra + (size_t)y * row_stride, v->width, v->lut);
        bgra = v->converted;
        row_stride = v->width * 4;
    }
    if (v->device) {
        AVFrame *input=av_frame_alloc(), *uploaded=av_frame_alloc();
        int result=-1;
        if (!input || !uploaded) goto upload_done;
        input->format=v->input_format; input->width=v->width; input->height=v->height;
        input->data[0]=(uint8_t*)bgra; input->linesize[0]=row_stride;
        if (av_hwframe_get_buffer(v->input_frames,uploaded,0)<0 || av_hwframe_transfer_data(uploaded,input,0)<0) goto upload_done;
        result=hardware_frame(v,uploaded,pts_us);
upload_done:
        av_frame_free(&input); av_frame_free(&uploaded);
        return result;
    }
    // The cached reference is obsolete when a fresh capture arrives. Drop it
    // before make_writable so it doesn't force a copy of the old YUV pixels.
    av_frame_unref(v->last);
    if (av_frame_make_writable(v->frame) < 0) return -1;
    for (int p=0;p<3;p++) {
        int h = p ? v->frame->height/2 : v->frame->height;
        memset(v->frame->data[p],p ? 128 : 16,v->frame->linesize[p]*h);
    }
    const uint8_t *data[4] = {bgra,NULL,NULL,NULL};
    int stride[4] = {row_stride,0,0,0};
    if (sws_scale(v->sws,data,stride,0,v->height,v->frame->data,v->frame->linesize) != v->height) return -1;
    v->frame->pts = pts_us;
    v->frame->duration = 1000000 / v->codec->framerate.num;
    if (av_frame_ref(v->last,v->frame)<0) return -1;
    return shot_video_repeat(v,pts_us);
}
int shot_video_close(ShotVideo *v) {
    int result = 0;
    if (avcodec_send_frame(v->codec,NULL) < 0 || drain(v) < 0) result = -1;
    if (v->header && av_write_trailer(v->format) < 0) result = -1;
    avio_flush(v->io);
    if (v->io->error < 0) result = -1;
    destroy(v);
    return result;
}
