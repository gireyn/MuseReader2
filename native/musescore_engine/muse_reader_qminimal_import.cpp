#include <QtPlugin>

Q_IMPORT_PLUGIN(QMinimalIntegrationPlugin)

// A static archive does not pull an object file solely because it contains a
// global plugin-registration constructor. The JNI shared library links this
// core through an archive, so expose a small link anchor and call it during
// engine initialization. That guarantees the Q_IMPORT_PLUGIN constructor is
// retained and the "minimal" QPA is visible to QGuiApplication.
extern "C" void muse_reader_qminimal_link_anchor() {}
