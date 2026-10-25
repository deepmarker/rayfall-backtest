#define _GNU_SOURCE
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <caml/mlvalues.h>
#include <caml/memory.h>
#include <caml/misc.h>
#include <caml/fail.h>
#include <caml/threads.h>
#include <caml/unixsupport.h>
#ifdef __linux__
#include <fcntl.h>
#include <sys/syscall.h>
#include <unistd.h>
#endif

/* Never fall back to replacing rename(2): a concurrent publisher or an
 * unrelated existing destination must survive. Called in an Async worker. */
CAMLprim value wb_rename_noreplace(value source, value destination)
{
    CAMLparam2(source, destination);
    if (strlen(String_val(source)) != caml_string_length(source) ||
        strlen(String_val(destination)) != caml_string_length(destination))
        caml_invalid_argument("rename_noreplace: NUL in path");
    char *src = caml_stat_strdup(String_val(source));
    char *dst = caml_stat_strdup(String_val(destination));
    caml_enter_blocking_section();
#if defined(__linux__) && defined(SYS_renameat2)
    int result = syscall(SYS_renameat2, AT_FDCWD, src,
                         AT_FDCWD, dst, RENAME_NOREPLACE);
#elif defined(__APPLE__) && defined(RENAME_EXCL)
    int result = renamex_np(src, dst, RENAME_EXCL);
#else
    errno = ENOTSUP;
    int result = -1;
#endif
    int saved_errno = errno;
    caml_leave_blocking_section();
    caml_stat_free(src);
    caml_stat_free(dst);
    if (result < 0) {
        errno = saved_errno;
        uerror("rename_noreplace", destination);
    }
    CAMLreturn(Val_unit);
}
