#include "fluid.h"

namespace FluidS {

// The reader has no Qt sound-font editor UI. Keeping the virtual method
// defined avoids pulling the desktop FluidGui and its generated widgets into
// the mobile binary.
Ms::SynthesizerGui* Fluid::gui() {
  return nullptr;
}

}  // namespace FluidS
