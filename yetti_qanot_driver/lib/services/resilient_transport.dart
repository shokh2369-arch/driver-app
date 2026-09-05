// Sticky, failover-aware TCP connections for hosts with several A records
// (the Render/Cloudflare edge). Native builds get the real implementation;
// web builds get a no-op — browsers manage their own sockets.
export 'resilient_transport_stub.dart'
    if (dart.library.io) 'resilient_transport_io.dart';
