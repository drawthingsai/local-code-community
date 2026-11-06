// ios_system's curl command. CurlPort.h maps the tool's and libcurl's file
// calls to the invocation's directory, which is set up here first.
void ios_system_support_init_directory(void);
int curl_tool_main(int argc, char *argv[]);

// The tool keeps its state in statics, expecting a new process for each run.
// ios_system runs curl again and again in one process (one job at a time, see
// curlRuntime), including after a cancelled run, so ios.patch adds these resets.
void ios_curl_reset_cfgable(void);
void ios_curl_reset_debug(void);
void ios_curl_reset_easysrc(void);
void ios_curl_reset_libinfo(void);
void ios_curl_reset_operate(void);
void ios_curl_reset_paramhlp(void);
void ios_curl_reset_progress(void);

int curl_main(int argc, char *argv[])
{
    ios_system_support_init_directory();
    ios_curl_reset_cfgable();
    ios_curl_reset_debug();
    ios_curl_reset_easysrc();
    ios_curl_reset_libinfo();
    ios_curl_reset_operate();
    ios_curl_reset_paramhlp();
    ios_curl_reset_progress();
    return curl_tool_main(argc, argv);
}
