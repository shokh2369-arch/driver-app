import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'resilient_http_client_io.dart';

/// Route [dio]'s connections through the sticky edge-address client
/// (see `resilient_http_client_io.dart`). Native only.
Dio withResilientTransport(Dio dio) {
  dio.httpClientAdapter = IOHttpClientAdapter(
    createHttpClient: createResilientHttpClient,
  );
  return dio;
}

/// `package:http` client on the same sticky, raced transport (for the
/// login-screen `/health` probe, which must not disagree with the Dio calls).
http.Client createResilientHttpPackageClient() =>
    IOClient(createResilientHttpClient());
