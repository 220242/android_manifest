/*
 * edge1-v4l2-probe: what the kernel's video accelerators offer, for the logs.
 *
 * For every /dev/videoN: driver, card, capabilities, and each format it takes
 * (OUTPUT - the coded side of a decoder) and gives (CAPTURE - the frames), with
 * the largest frame size. For every /dev/mediaN: driver and model. FFmpeg's
 * v4l2-request hwaccel pairs the two: it looks for a media device whose video
 * node takes a stateless coded format (S264 for H.264, VP9F, MG2S, VP8F).
 *
 * On 6.12 the RK3399 should show rkvdec (S264, VP9F) and hantro-vpu (MG2S,
 * VP8F; and a JPEG encoder), plus rockchip-rga. bin/edge1-bootwatch.sh runs this
 * into each snapshot's video.txt. See docs/HW_DECODE.md.
 */
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#include <linux/media.h>
#include <linux/videodev2.h>

static int by_number(const struct dirent **a, const struct dirent **b) {
    const char *x = (*a)->d_name, *y = (*b)->d_name;
    size_t lx = strlen(x), ly = strlen(y);
    return lx != ly ? (lx < ly ? -1 : 1) : strcmp(x, y);
}

static const char *prefix;
static int has_prefix(const struct dirent *d) {
    size_t n = strlen(prefix);
    return strncmp(d->d_name, prefix, n) == 0 && d->d_name[n] >= '0' && d->d_name[n] <= '9';
}

static void fourcc(unsigned int f, char out[5]) {
    for (int i = 0; i < 4; i++) {
        unsigned char c = (f >> (8 * i)) & 0xff;
        out[i] = c >= 32 && c < 127 ? (char)c : '?';
    }
    out[4] = '\0';
}

static void largest_size(int fd, unsigned int pixfmt) {
    struct v4l2_frmsizeenum fs;
    memset(&fs, 0, sizeof(fs));
    fs.pixel_format = pixfmt;
    if (ioctl(fd, VIDIOC_ENUM_FRAMESIZES, &fs) < 0) return;
    if (fs.type == V4L2_FRMSIZE_TYPE_DISCRETE) {
        unsigned int w = fs.discrete.width, h = fs.discrete.height;
        for (fs.index = 1; ioctl(fd, VIDIOC_ENUM_FRAMESIZES, &fs) == 0; fs.index++) {
            if (fs.discrete.width * fs.discrete.height > w * h) {
                w = fs.discrete.width;
                h = fs.discrete.height;
            }
        }
        printf("  up to %ux%u", w, h);
    } else {
        printf("  %ux%u..%ux%u", fs.stepwise.min_width, fs.stepwise.min_height,
               fs.stepwise.max_width, fs.stepwise.max_height);
    }
}

static void formats(int fd, unsigned int type, const char *label) {
    struct v4l2_fmtdesc d;
    memset(&d, 0, sizeof(d));
    d.type = type;
    for (d.index = 0; ioctl(fd, VIDIOC_ENUM_FMT, &d) == 0; d.index++) {
        char cc[5];
        fourcc(d.pixelformat, cc);
        printf("    %-7s %s  %-32s", label, cc, (const char *)d.description);
        if (d.flags & V4L2_FMT_FLAG_COMPRESSED) printf("  compressed");
        largest_size(fd, d.pixelformat);
        printf("\n");
    }
}

static void video(const char *path) {
    int fd = open(path, O_RDWR | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) {
        printf("%s: open: %s\n", path, strerror(errno));
        return;
    }
    struct v4l2_capability cap;
    memset(&cap, 0, sizeof(cap));
    if (ioctl(fd, VIDIOC_QUERYCAP, &cap) < 0) {
        printf("%s: VIDIOC_QUERYCAP: %s\n", path, strerror(errno));
        close(fd);
        return;
    }
    unsigned int caps = cap.capabilities & V4L2_CAP_DEVICE_CAPS ? cap.device_caps
                                                                : cap.capabilities;
    printf("%s: %s \"%s\" %s caps 0x%08x%s%s\n", path, (const char *)cap.driver,
           (const char *)cap.card, (const char *)cap.bus_info, caps,
           caps & (V4L2_CAP_VIDEO_M2M_MPLANE | V4L2_CAP_VIDEO_M2M) ? " m2m" : "",
           caps & V4L2_CAP_STREAMING ? " streaming" : "");
    if (caps & (V4L2_CAP_VIDEO_M2M_MPLANE | V4L2_CAP_VIDEO_OUTPUT_MPLANE))
        formats(fd, V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE, "output");
    if (caps & (V4L2_CAP_VIDEO_M2M | V4L2_CAP_VIDEO_OUTPUT))
        formats(fd, V4L2_BUF_TYPE_VIDEO_OUTPUT, "output");
    if (caps & (V4L2_CAP_VIDEO_M2M_MPLANE | V4L2_CAP_VIDEO_CAPTURE_MPLANE))
        formats(fd, V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE, "capture");
    if (caps & (V4L2_CAP_VIDEO_M2M | V4L2_CAP_VIDEO_CAPTURE))
        formats(fd, V4L2_BUF_TYPE_VIDEO_CAPTURE, "capture");
    close(fd);
}

static void media(const char *path) {
    int fd = open(path, O_RDWR | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) {
        printf("%s: open: %s\n", path, strerror(errno));
        return;
    }
    struct media_device_info info;
    memset(&info, 0, sizeof(info));
    if (ioctl(fd, MEDIA_IOC_DEVICE_INFO, &info) < 0) {
        printf("%s: MEDIA_IOC_DEVICE_INFO: %s\n", path, strerror(errno));
    } else {
        printf("%s: %s \"%s\" %s\n", path, info.driver, info.model, info.bus_info);
    }
    close(fd);
}

static int each(const char *pfx, void (*fn)(const char *)) {
    struct dirent **names;
    prefix = pfx;
    int n = scandir("/dev", &names, has_prefix, by_number);
    if (n < 0) {
        printf("/dev: %s\n", strerror(errno));
        return 0;
    }
    for (int i = 0; i < n; i++) {
        char path[300];
        snprintf(path, sizeof(path), "/dev/%s", names[i]->d_name);
        fn(path);
        free(names[i]);
    }
    free(names);
    return n;
}

int main(void) {
    if (each("video", video) == 0) printf("no /dev/video* nodes\n");
    printf("\n");
    if (each("media", media) == 0) printf("no /dev/media* nodes\n");
    return 0;
}
