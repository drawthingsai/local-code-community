#include "NodeMobile.h"

namespace node {
int Start(int argc, char* argv[]);
}

int node_start(int argc, char* argv[]) {
  return node::Start(argc, argv);
}
