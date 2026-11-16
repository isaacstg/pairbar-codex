#include "ProcessIdentity.h"
#include <libproc.h>
#include <string.h>
#include <errno.h>
int da_observe(int32_t pid, DAProcessSnapshot *output) {
    if (pid <= 0 || !output) return -1;
    struct proc_bsdinfo info = {0};
    errno = 0;
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info))
        return errno == ESRCH ? 0 : -1;
    memset(output, 0, sizeof(*output));
    if (proc_pidpath(pid, output->executable, sizeof(output->executable)) <= 0) return -1;
    struct proc_bsdinfo after = {0};
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &after, sizeof(after)) != sizeof(after) ||
        after.pbi_uid != info.pbi_uid || after.pbi_start_tvsec != info.pbi_start_tvsec ||
        after.pbi_start_tvusec != info.pbi_start_tvusec) return -1;
    output->pid = pid; output->uid = info.pbi_uid;
    output->seconds = info.pbi_start_tvsec; output->microseconds = info.pbi_start_tvusec;
    return 1;
}
int da_snapshot(int32_t pid, DAProcessSnapshot *output) {
    return da_observe(pid, output) == 1;
}
