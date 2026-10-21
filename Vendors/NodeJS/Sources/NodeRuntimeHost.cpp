#include "NodeMobile.h"

#include <errno.h>
#include <limits.h>
#include <unistd.h>

#include <atomic>
#include <memory>
#include <mutex>
#include <sstream>
#include <string>
#include <string_view>
#include <unordered_map>
#include <utility>
#include <vector>

#include "node.h"
#include "node_options-inl.h"
#include "node_version.h"
#include "v8.h"

namespace {

struct CommandState {
  std::atomic<bool> cancelled = false;
  node::Environment* environment = nullptr;
  bool started = false;
  bool running = false;
};

struct CommandOptions {
  std::string working_directory;
  std::string preload_path;
  std::vector<std::string> environment;
  bool has_environment = false;
  int stdin_fd = -1;
  int stdout_fd = -1;
  int stderr_fd = -1;
};

struct ParsedCommand {
  std::vector<std::string> arguments;
  std::vector<std::string> exec_arguments;
  std::vector<std::string> ignored_v8_arguments;
  std::vector<std::string> errors;
  std::shared_ptr<node::PerProcessOptions> options;
};

std::once_flag initialization_once;
std::shared_ptr<node::InitializationResult> initialization;
node::MultiIsolatePlatform* platform = nullptr;
int initialization_status = 1;
std::string initialization_error;
std::mutex command_mutex;
std::mutex command_state_mutex;
std::unordered_map<uint64_t, std::unique_ptr<CommandState>> command_states;

void WriteAll(int descriptor, std::string_view value) {
  if (descriptor < 0) {
    return;
  }
  while (!value.empty()) {
    ssize_t written = write(descriptor, value.data(), value.size());
    if (written > 0) {
      value.remove_prefix(static_cast<size_t>(written));
      continue;
    }
    if (written < 0 && errno == EINTR) {
      continue;
    }
    return;
  }
}

std::string QuoteJavaScript(std::string_view value) {
  static constexpr char hexadecimal[] = "0123456789abcdef";
  std::string result;
  result.reserve(value.size() + 2);
  result.push_back('"');
  for (unsigned char character : value) {
    switch (character) {
      case '"':
        result += "\\\"";
        break;
      case '\\':
        result += "\\\\";
        break;
      case '\b':
        result += "\\b";
        break;
      case '\f':
        result += "\\f";
        break;
      case '\n':
        result += "\\n";
        break;
      case '\r':
        result += "\\r";
        break;
      case '\t':
        result += "\\t";
        break;
      default:
        if (character < 0x20) {
          result += "\\u00";
          result.push_back(hexadecimal[character >> 4]);
          result.push_back(hexadecimal[character & 0x0f]);
        } else {
          result.push_back(static_cast<char>(character));
        }
        break;
    }
  }
  result.push_back('"');
  return result;
}

CommandOptions SnapshotOptions(const node_mobile_command_options& options) {
  CommandOptions snapshot;
  if (options.working_directory != nullptr) {
    snapshot.working_directory = options.working_directory;
  }
  if (options.preload_path != nullptr) {
    snapshot.preload_path = options.preload_path;
  }
  snapshot.has_environment = options.environment != nullptr;
  if (options.environment != nullptr) {
    for (const char* const* item = options.environment; *item != nullptr;
         ++item) {
      snapshot.environment.emplace_back(*item);
    }
  }
  snapshot.stdin_fd = options.stdin_fd;
  snapshot.stdout_fd = options.stdout_fd;
  snapshot.stderr_fd = options.stderr_fd;
  return snapshot;
}

ParsedCommand ParseCommand(int argc, char* argv[]) {
  ParsedCommand command;
  std::vector<std::string> command_line;
  command_line.reserve(argc);
  for (int index = 0; index < argc; ++index) {
    command_line.emplace_back(argv[index]);
  }

  {
    node::Mutex::ScopedLock lock(node::per_process::cli_options_mutex);
    command.options = std::make_shared<node::PerProcessOptions>(
        *node::per_process::cli_options);
    command.options->per_isolate =
        node::per_process::cli_options->per_isolate->Clone();
  }
  command.options->cmdline = command_line;
  command.arguments = std::move(command_line);
  node::options_parser::Parse(
      &command.arguments,
      &command.exec_arguments,
      &command.ignored_v8_arguments,
      command.options.get(),
      node::kDisallowedInEnvvar,
      &command.errors);
  return command;
}

std::string BuildEmbedderPreload(const CommandOptions& options) {
  std::ostringstream source;
  source
      << "\"use strict\";\n"
      << "const fs = require(\"fs\");\n"
      << "const { Console } = require(\"console\");\n"
      << "const { Writable } = require(\"stream\");\n"
      << "const __createSyncWriteStream = (__fd) => {\n"
      << " const __stream = new Writable({\n"
      << "  write(__chunk,__encoding,__callback) {\n"
      << "   try {\n"
      << "    if (typeof __chunk === \"string\") "
         "__chunk = Buffer.from(__chunk,__encoding);\n"
      << "    let __offset = 0;\n"
      << "    while (__offset < __chunk.length) {\n"
      << "     const __written = fs.writeSync("
         "__fd,__chunk,__offset,__chunk.length-__offset);\n"
      << "     if (__written === 0) throw new Error("
         "\"unable to write command output\");\n"
      << "     __offset += __written;\n"
      << "    }\n"
      << "    __callback();\n"
      << "   } catch (__error) { __callback(__error); }\n"
      << "  }\n"
      << " });\n"
      << " Object.defineProperty(__stream,\"fd\","
         "{value:__fd,enumerable:true});\n"
      << " return __stream;\n"
      << "};\n"
      << "const __stdout = __createSyncWriteStream(" << options.stdout_fd
      << ");\n"
      << "const __stderr = __createSyncWriteStream(" << options.stderr_fd
      << ");\n"
      << "let __stdin;\n"
      << "Object.defineProperties(process, {\n"
      << " stdout:{configurable:true,enumerable:true,get:()=>__stdout},\n"
      << " stderr:{configurable:true,enumerable:true,get:()=>__stderr},\n"
      << " stdin:{configurable:true,enumerable:true,get:()=>"
         "(__stdin||(__stdin=fs.createReadStream(\"\",{fd:"
      << options.stdin_fd << ",autoClose:false}))) }\n"
      << "});\n"
      << "globalThis.console = new Console({stdout:__stdout,stderr:__stderr,"
         "colorMode:false});\n"
      << "const __reportFatal = (__error) => {\n"
      << " const __text = __error && __error.stack ? __error.stack : "
         "String(__error);\n"
      << " try { fs.writeSync(" << options.stderr_fd
      << ", __text + \"\\n\"); } finally { process.exit(1); }\n"
      << "};\n"
      << "process.on(\"uncaughtException\", __reportFatal);\n"
      << "process.on(\"unhandledRejection\", __reportFatal);\n";

  if (options.has_environment) {
    source << "const __environmentEntries = [";
    bool first = true;
    for (const std::string& item : options.environment) {
      std::string_view entry(item);
      size_t separator = entry.find('=');
      if (separator == std::string_view::npos ||
          entry.substr(0, separator) == "NODE_OPTIONS") {
        continue;
      }
      if (!first) {
        source << ',';
      }
      first = false;
      source << '[' << QuoteJavaScript(entry.substr(0, separator)) << ','
             << QuoteJavaScript(entry.substr(separator + 1)) << ']';
    }
    source
        << "];\n"
        << "const __setEnvironmentValue = (__target,__key,__value) => "
           "typeof __key === \"symbol\" ? "
           "Reflect.set(__target,__key,__value) : "
           "Reflect.defineProperty(__target,__key,{configurable:true,"
           "enumerable:true,writable:true,value:String(__value)});\n"
        << "const __environmentValues = "
           "Object.create(Object.getPrototypeOf(process.env));\n"
        << "for (const [__key,__value] of __environmentEntries) "
           "__setEnvironmentValue(__environmentValues,__key,__value);\n"
        << "const __environment = new Proxy(__environmentValues, {\n"
        << " set:__setEnvironmentValue\n"
        << "});\n"
        << "Object.defineProperty(process,\"env\",{configurable:true,"
           "enumerable:true,writable:true,value:__environment});\n";
  }
  return source.str();
}

void RunEmbedderPreload(
    const std::string& source,
    v8::Local<v8::Value> process,
    v8::Local<v8::Value> require) {
  v8::Isolate* isolate = v8::Isolate::GetCurrent();
  v8::Local<v8::Context> context = isolate->GetCurrentContext();
  v8::Local<v8::String> source_string;
  if (!v8::String::NewFromUtf8(
           isolate,
           source.data(),
           v8::NewStringType::kNormal,
           static_cast<int>(source.size()))
           .ToLocal(&source_string)) {
    return;
  }
  v8::ScriptCompiler::Source script_source(source_string);
  v8::Local<v8::String> parameter =
      v8::String::NewFromUtf8Literal(isolate, "require");
  v8::Local<v8::Function> function;
  if (!v8::ScriptCompiler::CompileFunction(
           context, &script_source, 1, &parameter)
           .ToLocal(&function)) {
    return;
  }
  v8::Local<v8::Value> arguments[] = {require};
  static_cast<void>(function->Call(context, process, 1, arguments));
}

void InitializeNodeMobileHost() {
  std::vector<std::string> arguments = {
      "node", "--jitless", "--wasm-jitless"};
  initialization = node::InitializeOncePerProcess(
      arguments,
      {
          node::ProcessInitializationFlags::kDisableNodeOptionsEnv,
          node::ProcessInitializationFlags::kNoStdioInitialization,
          node::ProcessInitializationFlags::kNoDefaultSignalHandling,
          node::ProcessInitializationFlags::kNoParseGlobalDebugVariables,
          node::ProcessInitializationFlags::kNoAdjustResourceLimits,
          node::ProcessInitializationFlags::kNoUseLargePages,
      });
  for (const std::string& error : initialization->errors()) {
    if (!initialization_error.empty()) {
      initialization_error.push_back('\n');
    }
    initialization_error += error;
  }
  if (initialization->early_return()) {
    initialization_status = initialization->exit_code();
    if (initialization_status == 0) {
      initialization_status = 1;
    }
    if (initialization_error.empty()) {
      initialization_error =
          "Node initialization returned before creating a runtime";
    }
    return;
  }
  platform = initialization->platform();
  if (platform == nullptr) {
    initialization_error = "Node initialization did not create a V8 platform";
    return;
  }
  initialization_status = 0;
}

class RunningCommandScope {
 public:
  explicit RunningCommandScope(CommandState* state) : state_(state) {}

  ~RunningCommandScope() {
    std::lock_guard<std::mutex> lock(command_state_mutex);
    state_->environment = nullptr;
    state_->running = false;
  }

 private:
  CommandState* state_;
};

class WorkingDirectoryScope {
 public:
  explicit WorkingDirectoryScope(const char* requested) {
    if (getcwd(original_, sizeof(original_)) == nullptr) {
      error_ = "unable to read the current working directory";
      return;
    }
    restore_ = true;
    if (requested != nullptr && requested[0] != '\0' &&
        chdir(requested) != 0) {
      error_ = "unable to enter working directory ";
      error_ += requested;
    }
  }

  ~WorkingDirectoryScope() {
    if (restore_) {
      chdir(original_);
    }
  }

  bool valid() const { return error_.empty(); }
  const std::string& error() const { return error_; }

 private:
  char original_[PATH_MAX] = {};
  bool restore_ = false;
  std::string error_;
};

class CommandLineOptionsScope {
 public:
  explicit CommandLineOptionsScope(
      std::shared_ptr<node::PerProcessOptions> options) {
    node::Mutex::ScopedLock lock(node::per_process::cli_options_mutex);
    previous_ = node::per_process::cli_options;
    node::per_process::cli_options = std::move(options);
  }

  ~CommandLineOptionsScope() {
    node::Mutex::ScopedLock lock(node::per_process::cli_options_mutex);
    node::per_process::cli_options = std::move(previous_);
  }

 private:
  std::shared_ptr<node::PerProcessOptions> previous_;
};

}  // namespace

int node_mobile_prepare_command(uint64_t command_identifier) {
  if (command_identifier == 0) {
    return EINVAL;
  }
  std::lock_guard<std::mutex> state_lock(command_state_mutex);
  if (command_states.find(command_identifier) != command_states.end()) {
    return EEXIST;
  }
  command_states.emplace(command_identifier, std::make_unique<CommandState>());
  return 0;
}

int node_mobile_run_command(
    int argc,
    char* argv[],
    const node_mobile_command_options* options) {
  if (argc < 1 || argv == nullptr || options == nullptr) {
    return 1;
  }
  if (options->command_identifier == 0 || options->stdin_fd < 0 ||
      options->stdout_fd < 0 || options->stderr_fd < 0) {
    return 1;
  }

  CommandState* command_state;
  {
    std::lock_guard<std::mutex> state_lock(command_state_mutex);
    auto item = command_states.find(options->command_identifier);
    if (item == command_states.end()) {
      WriteAll(
          options->stderr_fd,
          "node: command identifier was not prepared\n");
      return 1;
    }
    command_state = item->second.get();
    if (command_state->started) {
      WriteAll(
          options->stderr_fd,
          "node: command identifier was already started\n");
      return 1;
    }
    command_state->started = true;
    command_state->running = true;
  }
  RunningCommandScope running_command(command_state);
  CommandOptions command_options = SnapshotOptions(*options);

  std::lock_guard<std::mutex> command_lock(command_mutex);
  if (command_state->cancelled) {
    return 130;
  }

  std::call_once(initialization_once, InitializeNodeMobileHost);
  if (initialization_status != 0) {
    WriteAll(
        command_options.stderr_fd,
        "node: " +
            (initialization_error.empty()
                 ? std::string("runtime initialization failed")
                 : initialization_error) +
            "\n");
    return initialization_status;
  }
  if (command_state->cancelled) {
    return 130;
  }

  ParsedCommand command = ParseCommand(argc, argv);
  if (!command.errors.empty()) {
    for (const std::string& error : command.errors) {
      WriteAll(command_options.stderr_fd, "node: " + error + "\n");
    }
    return 9;
  }
  if (command.options->print_version) {
    WriteAll(
        command_options.stdout_fd,
        std::string("v") + NODE_VERSION_STRING + "\n");
    return 0;
  }
  if (command.options->print_bash_completion) {
    WriteAll(
        command_options.stdout_fd,
        node::options_parser::GetBashCompletion() + "\n");
    return 0;
  }
  if (command.options->print_v8_help) {
    return 0;
  }
  if (!command.options->run.empty() ||
      !command.options->experimental_sea_config.empty() ||
      !command.options->snapshot_blob.empty() ||
      command.options->per_isolate->build_snapshot) {
    WriteAll(
        command_options.stderr_fd,
        "node: this startup-only option is unavailable in the reusable "
        "embedded runtime\n");
    return 9;
  }

  node::EnvironmentOptions* environment_options =
      command.options->per_isolate->per_env.get();
  bool reads_stdin =
      !environment_options->has_eval_string &&
      (command.arguments.size() < 2 || command.arguments[1] == "-");
  if (environment_options->force_repl ||
      (!command.options->print_help && reads_stdin &&
       isatty(command_options.stdin_fd))) {
    WriteAll(
        command_options.stderr_fd,
        "node: interactive mode is not supported by ios_system; use a "
        "script, -e, or pipe stdin.\n");
    return 1;
  }
  if (!command_options.preload_path.empty()) {
    environment_options->preload_cjs_modules.insert(
        environment_options->preload_cjs_modules.begin(),
        command_options.preload_path);
  }

  WorkingDirectoryScope working_directory(
      command_options.working_directory.c_str());
  if (!working_directory.valid()) {
    WriteAll(
        command_options.stderr_fd,
        "node: " + working_directory.error() + "\n");
    return 1;
  }

  CommandLineOptionsScope command_line_options(command.options);
  std::vector<std::string> errors;
  std::unique_ptr<node::CommonEnvironmentSetup> setup =
      node::CommonEnvironmentSetup::Create(
          platform,
          &errors,
          command.arguments,
          command.exec_arguments);
  if (!setup) {
    std::string environment_error;
    for (const std::string& error : errors) {
      if (!environment_error.empty()) {
        environment_error.push_back('\n');
      }
      environment_error += error;
    }
    WriteAll(
        command_options.stderr_fd,
        "node: " +
            (environment_error.empty()
                 ? std::string("environment creation failed")
                 : environment_error) +
            "\n");
    return 1;
  }

  node::Environment* environment = setup->env();
  int exit_code = 0;
  bool requested_exit = false;
  node::SetProcessExitHandler(
      environment,
      [&](node::Environment* exiting_environment, int requested_code) {
        exit_code = requested_code;
        requested_exit = true;
        node::Stop(exiting_environment);
      });
  {
    std::lock_guard<std::mutex> state_lock(command_state_mutex);
    command_state->environment = environment;
  }
  if (command_state->cancelled) {
    {
      std::lock_guard<std::mutex> state_lock(command_state_mutex);
      command_state->environment = nullptr;
    }
    node::Stop(environment);
    return 130;
  }

  {
    v8::Locker locker(setup->isolate());
    v8::Isolate::Scope isolate_scope(setup->isolate());
    v8::HandleScope handle_scope(setup->isolate());
    v8::Context::Scope context_scope(setup->context());
    std::string preload = BuildEmbedderPreload(command_options);
    node::EmbedderPreloadCallback preload_callback =
        [main_environment = environment, preload = std::move(preload)](
            node::Environment* current_environment,
            v8::Local<v8::Value> process,
            v8::Local<v8::Value> require) {
          if (current_environment != main_environment) {
            return;
          }
          RunEmbedderPreload(preload, process, require);
        };
    if (node::LoadEnvironment(
            environment,
            node::StartExecutionCallbackWithModule{},
            std::move(preload_callback))
            .IsEmpty()) {
      exit_code = requested_exit ? exit_code : 1;
    } else {
      v8::Maybe<int> result = node::SpinEventLoop(environment);
      if (!result.IsNothing()) {
        exit_code = result.FromJust();
      } else if (command_state->cancelled) {
        exit_code = 130;
      } else if (!requested_exit) {
        exit_code = 1;
      }
    }
  }

  {
    std::lock_guard<std::mutex> state_lock(command_state_mutex);
    command_state->environment = nullptr;
  }
  node::Stop(environment);
  if (command_state->cancelled) {
    return 130;
  }
  return exit_code;
}

int node_mobile_cancel_command(uint64_t command_identifier) {
  if (command_identifier == 0) {
    return EINVAL;
  }
  std::lock_guard<std::mutex> state_lock(command_state_mutex);
  auto item = command_states.find(command_identifier);
  if (item == command_states.end()) {
    return ESRCH;
  }
  CommandState* state = item->second.get();
  state->cancelled = true;
  if (state->environment != nullptr) {
    node::Stop(state->environment);
  }
  return 0;
}

int node_mobile_finish_command(
    uint64_t command_identifier, int* cancellation_requested) {
  if (cancellation_requested != nullptr) {
    *cancellation_requested = 0;
  }
  if (command_identifier == 0) {
    return EINVAL;
  }
  std::lock_guard<std::mutex> state_lock(command_state_mutex);
  auto item = command_states.find(command_identifier);
  if (item == command_states.end()) {
    return ESRCH;
  }
  if (item->second->running || item->second->environment != nullptr) {
    return EBUSY;
  }
  if (cancellation_requested != nullptr) {
    *cancellation_requested = item->second->cancelled ? 1 : 0;
  }
  command_states.erase(item);
  return 0;
}
