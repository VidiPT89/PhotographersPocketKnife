#import "PPKCurl.h"
#import <curl/curl.h>
#import <sys/stat.h>

struct PPKProgress { __unsafe_unretained PPKCurl *owner; __unsafe_unretained void (^block)(double); };
static int progressCallback(void *p, curl_off_t totalDown, curl_off_t down, curl_off_t totalUp, curl_off_t up) {
    struct PPKProgress *state = p;
    if (state->owner.cancelled) return 1;
    if (totalUp > 0) state->block((double)up / totalUp);
    return 0;
}
static size_t discardResponse(char *ptr, size_t size, size_t count, void *context) { return size * count; }
@implementation PPKCurl
- (BOOL)performURL:(NSString *)url file:(NSString *)file username:(NSString *)username password:(NSString *)password tls:(BOOL)tls signature:(NSString *)signature method:(NSString *)method caBundle:(NSString *)caBundle progress:(void (^)(double))progress error:(NSError **)error {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ curl_global_init(CURL_GLOBAL_DEFAULT); });
    CURL *curl = curl_easy_init();
    if (!curl) { if (error) *error = [NSError errorWithDomain:@"PPKTransfer" code:2 userInfo:nil]; return NO; }
    FILE *input = NULL;
    struct curl_slist *headers = NULL;
    char message[CURL_ERROR_SIZE] = {0};
    struct PPKProgress state = {self, progress};
    curl_easy_setopt(curl, CURLOPT_URL, url.UTF8String);
    curl_easy_setopt(curl, CURLOPT_USERNAME, username.UTF8String);
    curl_easy_setopt(curl, CURLOPT_PASSWORD, password.UTF8String);
    curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT, 20L);
    curl_easy_setopt(curl, CURLOPT_LOW_SPEED_LIMIT, 1L);
    curl_easy_setopt(curl, CURLOPT_LOW_SPEED_TIME, 60L);
    curl_easy_setopt(curl, CURLOPT_NOSIGNAL, 1L);
    curl_easy_setopt(curl, CURLOPT_FAILONERROR, 1L);
    curl_easy_setopt(curl, CURLOPT_ERRORBUFFER, message);
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, discardResponse);
    curl_easy_setopt(curl, CURLOPT_NOPROGRESS, 0L);
    curl_easy_setopt(curl, CURLOPT_XFERINFOFUNCTION, progressCallback);
    curl_easy_setopt(curl, CURLOPT_XFERINFODATA, &state);
    curl_easy_setopt(curl, CURLOPT_CAINFO, caBundle.UTF8String);
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYPEER, 1L);
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYHOST, 2L);
    curl_easy_setopt(curl, CURLOPT_FTP_CREATE_MISSING_DIRS, (long)CURLFTP_CREATE_DIR_RETRY);
    if (tls) curl_easy_setopt(curl, CURLOPT_USE_SSL, (long)CURLUSESSL_ALL);
    if (signature) curl_easy_setopt(curl, CURLOPT_AWS_SIGV4, signature.UTF8String);
    if (method) {
        curl_easy_setopt(curl, CURLOPT_CUSTOMREQUEST, method.UTF8String);
        headers = curl_slist_append(headers, "Depth: 0");
        curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headers);
    }
    if (file) {
        input = fopen(file.fileSystemRepresentation, "rb");
        if (!input) { curl_easy_cleanup(curl); curl_slist_free_all(headers); if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil]; return NO; }
        struct stat info; fstat(fileno(input), &info);
        curl_easy_setopt(curl, CURLOPT_UPLOAD, 1L);
        curl_easy_setopt(curl, CURLOPT_READDATA, input);
        curl_easy_setopt(curl, CURLOPT_INFILESIZE_LARGE, (curl_off_t)info.st_size);
    } else if (!method) {
        curl_easy_setopt(curl, CURLOPT_NOBODY, 1L);
    }
    CURLcode result = self.cancelled ? CURLE_ABORTED_BY_CALLBACK : curl_easy_perform(curl);
    long response = 0;
    curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &response);
    curl_easy_cleanup(curl);
    curl_slist_free_all(headers);
    if (input) fclose(input);
    // Existing WebDAV collections report 405.
    if (result != CURLE_OK && !([method isEqualToString:@"MKCOL"] && response == 405)) {
        NSString *description = message[0] ? @(message) : @(curl_easy_strerror(result));
        if (error) *error = [NSError errorWithDomain:@"PPKTransfer" code:result userInfo:@{NSLocalizedDescriptionKey:description}];
        return NO;
    }
    return YES;
}
@end
