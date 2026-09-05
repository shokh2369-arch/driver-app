import 'package:dio/dio.dart';
import 'package:http/http.dart' as http;

/// Web: the browser owns the sockets; nothing to install.
Dio withResilientTransport(Dio dio) => dio;

/// Web: the browser owns the sockets.
http.Client createResilientHttpPackageClient() => http.Client();
