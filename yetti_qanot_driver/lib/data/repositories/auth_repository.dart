import '../../services/auth_api_client.dart' show AuthApiClient, PhoneAuthResult;

class AuthRepository {
  AuthRepository(this._api);

  final AuthApiClient _api;

  Future<void> requestCode(String phone) => _api.requestCode(phone);

  Future<PhoneAuthResult> verifyCode(String phone, String code) => _api.verifyCode(phone, code);
}
