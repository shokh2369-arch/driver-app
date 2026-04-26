import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_uz.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'arb/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('uz'),
    Locale.fromSubtags(languageCode: 'uz', scriptCode: 'Cyrl'),
  ];

  /// No description provided for @online.
  ///
  /// In uz, this message translates to:
  /// **'Online'**
  String get online;

  /// No description provided for @offline.
  ///
  /// In uz, this message translates to:
  /// **'Offline'**
  String get offline;

  /// No description provided for @start_trip.
  ///
  /// In uz, this message translates to:
  /// **'Safarni boshlash'**
  String get start_trip;

  /// No description provided for @finish_trip.
  ///
  /// In uz, this message translates to:
  /// **'Safarni tugatish'**
  String get finish_trip;

  /// No description provided for @cancel_trip.
  ///
  /// In uz, this message translates to:
  /// **'Safarni bekor qilish'**
  String get cancel_trip;

  /// No description provided for @arrived.
  ///
  /// In uz, this message translates to:
  /// **'Yetib keldim'**
  String get arrived;

  /// No description provided for @to_pickup.
  ///
  /// In uz, this message translates to:
  /// **'Mijozga yo’lda'**
  String get to_pickup;

  /// No description provided for @trip_status_ready_to_start.
  ///
  /// In uz, this message translates to:
  /// **'Safarni boshlash mumkin'**
  String get trip_status_ready_to_start;

  /// No description provided for @trip_arrived_need_closer.
  ///
  /// In uz, this message translates to:
  /// **'Mijozga ~100 m yaqin bo‘ling — «Yetib keldim» ochiladi.'**
  String get trip_arrived_need_closer;

  /// No description provided for @unfinished_trip_title.
  ///
  /// In uz, this message translates to:
  /// **'Tugallanmagan safar'**
  String get unfinished_trip_title;

  /// No description provided for @unfinished_trip_phase_started.
  ///
  /// In uz, this message translates to:
  /// **'Safar davom etmoqda'**
  String get unfinished_trip_phase_started;

  /// No description provided for @trip_completes_on_server_hint.
  ///
  /// In uz, this message translates to:
  /// **'Safar tugashi haydovchi ilovasidan emas — tizim holatni yangilaydi.'**
  String get trip_completes_on_server_hint;

  /// No description provided for @trip_finish_hint.
  ///
  /// In uz, this message translates to:
  /// **'Tugatish buyurtmani yakunlaydi va holat serverga yuboriladi.'**
  String get trip_finish_hint;

  /// No description provided for @trip_completed_dialog_title.
  ///
  /// In uz, this message translates to:
  /// **'Safar tugadi'**
  String get trip_completed_dialog_title;

  /// No description provided for @trip_completed_ok.
  ///
  /// In uz, this message translates to:
  /// **'Yaxshi'**
  String get trip_completed_ok;

  /// No description provided for @unfinished_trip_continue.
  ///
  /// In uz, this message translates to:
  /// **'Davom etish'**
  String get unfinished_trip_continue;

  /// No description provided for @trip_plan_not_found.
  ///
  /// In uz, this message translates to:
  /// **'Reja topilmadi'**
  String get trip_plan_not_found;

  /// No description provided for @enable_location.
  ///
  /// In uz, this message translates to:
  /// **'Lokatsiyani yoqing'**
  String get enable_location;

  /// No description provided for @allow_location.
  ///
  /// In uz, this message translates to:
  /// **'Lokatsiyaga ruxsat bering'**
  String get allow_location;

  /// No description provided for @balance.
  ///
  /// In uz, this message translates to:
  /// **'Balans'**
  String get balance;

  /// No description provided for @promo_balance.
  ///
  /// In uz, this message translates to:
  /// **'Promo balans'**
  String get promo_balance;

  /// No description provided for @cash_balance.
  ///
  /// In uz, this message translates to:
  /// **'Naqd balans'**
  String get cash_balance;

  /// No description provided for @accept.
  ///
  /// In uz, this message translates to:
  /// **'Qabul qilish'**
  String get accept;

  /// No description provided for @auto_offer.
  ///
  /// In uz, this message translates to:
  /// **'Avto-taklif'**
  String get auto_offer;

  /// No description provided for @orders.
  ///
  /// In uz, this message translates to:
  /// **'Buyurtmalar'**
  String get orders;

  /// No description provided for @trip_history_title.
  ///
  /// In uz, this message translates to:
  /// **'Safarlar tarixi'**
  String get trip_history_title;

  /// No description provided for @trip_history_empty.
  ///
  /// In uz, this message translates to:
  /// **'Hozircha yakunlangan safarlar yo‘q. Ro‘yxat serverdan yuklanadi.'**
  String get trip_history_empty;

  /// No description provided for @available_requests_title.
  ///
  /// In uz, this message translates to:
  /// **'Mavjud buyurtmalar'**
  String get available_requests_title;

  /// No description provided for @available_requests_empty.
  ///
  /// In uz, this message translates to:
  /// **'Hozircha navbatdagi buyurtmalar yo‘q.'**
  String get available_requests_empty;

  /// No description provided for @available_requests_no_api.
  ///
  /// In uz, this message translates to:
  /// **'Server manzili sozlanmagan.'**
  String get available_requests_no_api;

  /// No description provided for @available_requests_load_error.
  ///
  /// In uz, this message translates to:
  /// **'Ro‘yxatni yuklab bo‘lmadi. Internetni tekshiring.'**
  String get available_requests_load_error;

  /// No description provided for @dist_to_pickup.
  ///
  /// In uz, this message translates to:
  /// **'Mijozgacha'**
  String get dist_to_pickup;

  /// No description provided for @trip_route_km.
  ///
  /// In uz, this message translates to:
  /// **'Safar'**
  String get trip_route_km;

  /// No description provided for @from_place.
  ///
  /// In uz, this message translates to:
  /// **'Qayerdan'**
  String get from_place;

  /// No description provided for @to_place.
  ///
  /// In uz, this message translates to:
  /// **'Qayerga'**
  String get to_place;

  /// No description provided for @parking_off.
  ///
  /// In uz, this message translates to:
  /// **'To‘xtashda emas'**
  String get parking_off;

  /// No description provided for @commission_banner.
  ///
  /// In uz, this message translates to:
  /// **'Buyurtmadan 5%'**
  String get commission_banner;

  /// No description provided for @settings.
  ///
  /// In uz, this message translates to:
  /// **'Sozlamalar'**
  String get settings;

  /// No description provided for @theme_title.
  ///
  /// In uz, this message translates to:
  /// **'Ko‘rinish'**
  String get theme_title;

  /// No description provided for @theme_system.
  ///
  /// In uz, this message translates to:
  /// **'Tizim'**
  String get theme_system;

  /// No description provided for @theme_light.
  ///
  /// In uz, this message translates to:
  /// **'Yorug‘'**
  String get theme_light;

  /// No description provided for @theme_dark.
  ///
  /// In uz, this message translates to:
  /// **'To‘q'**
  String get theme_dark;

  /// No description provided for @language_title.
  ///
  /// In uz, this message translates to:
  /// **'Til'**
  String get language_title;

  /// No description provided for @language_option_latin.
  ///
  /// In uz, this message translates to:
  /// **'Oʻzbekcha'**
  String get language_option_latin;

  /// No description provided for @language_option_cyrillic.
  ///
  /// In uz, this message translates to:
  /// **'Ўзбекча'**
  String get language_option_cyrillic;

  /// No description provided for @language_use_device.
  ///
  /// In uz, this message translates to:
  /// **'Qurilma tili'**
  String get language_use_device;

  /// No description provided for @referral_link_label.
  ///
  /// In uz, this message translates to:
  /// **'Referal havolasi'**
  String get referral_link_label;

  /// No description provided for @copy_action.
  ///
  /// In uz, this message translates to:
  /// **'Nusxa olish'**
  String get copy_action;

  /// No description provided for @copied_to_clipboard.
  ///
  /// In uz, this message translates to:
  /// **'Havola buferga nusxalandi'**
  String get copied_to_clipboard;

  /// No description provided for @sign_out.
  ///
  /// In uz, this message translates to:
  /// **'Chiqish'**
  String get sign_out;

  /// No description provided for @call.
  ///
  /// In uz, this message translates to:
  /// **'Qo‘ng‘iroq'**
  String get call;

  /// No description provided for @trip_customer_label.
  ///
  /// In uz, this message translates to:
  /// **'Mijoz'**
  String get trip_customer_label;

  /// No description provided for @trip_price_label.
  ///
  /// In uz, this message translates to:
  /// **'Narx'**
  String get trip_price_label;

  /// No description provided for @trip_distance_label.
  ///
  /// In uz, this message translates to:
  /// **'Masofa'**
  String get trip_distance_label;

  /// No description provided for @trip_map_stats_minutes.
  ///
  /// In uz, this message translates to:
  /// **'{minutes} daqiqa'**
  String trip_map_stats_minutes(int minutes);

  /// No description provided for @driver_id_title.
  ///
  /// In uz, this message translates to:
  /// **'Haydovchi ID'**
  String get driver_id_title;

  /// No description provided for @driver_id_subtitle.
  ///
  /// In uz, this message translates to:
  /// **'Ichki users.id yoki Telegram telegram_id (tasdiqlangan haydovchi). Admin / bot bilan bir xil.'**
  String get driver_id_subtitle;

  /// No description provided for @driver_id_hint.
  ///
  /// In uz, this message translates to:
  /// **'Masalan: 123456789'**
  String get driver_id_hint;

  /// No description provided for @driver_id_save.
  ///
  /// In uz, this message translates to:
  /// **'Saqlash'**
  String get driver_id_save;

  /// No description provided for @driver_id_error_empty.
  ///
  /// In uz, this message translates to:
  /// **'ID kiritilmagan'**
  String get driver_id_error_empty;

  /// No description provided for @driver_id_error_digits.
  ///
  /// In uz, this message translates to:
  /// **'Faqat raqamlar: ichki users.id yoki Telegram ID'**
  String get driver_id_error_digits;

  /// No description provided for @legal_acceptance_title.
  ///
  /// In uz, this message translates to:
  /// **'Huquqiy hujjatlar'**
  String get legal_acceptance_title;

  /// No description provided for @legal_acceptance_subtitle.
  ///
  /// In uz, this message translates to:
  /// **'Davom etishdan oldin quyidagi shartlarni qabul qiling.'**
  String get legal_acceptance_subtitle;

  /// No description provided for @legal_acceptance_confirm.
  ///
  /// In uz, this message translates to:
  /// **'Qabul qilaman'**
  String get legal_acceptance_confirm;

  /// No description provided for @retry.
  ///
  /// In uz, this message translates to:
  /// **'Qayta urinish'**
  String get retry;

  /// No description provided for @offline_api_failed.
  ///
  /// In uz, this message translates to:
  /// **'Offline rejimga o‘tib bo‘lmadi. Internetni tekshirib, qayta urinib ko‘ring.'**
  String get offline_api_failed;

  /// No description provided for @phone_login_title.
  ///
  /// In uz, this message translates to:
  /// **'Kirish'**
  String get phone_login_title;

  /// No description provided for @phone_login_subtitle.
  ///
  /// In uz, this message translates to:
  /// **'Telefon raqamingizni kiriting — SMS orqali kod yuboramiz.'**
  String get phone_login_subtitle;

  /// No description provided for @phone_login_phone_hint.
  ///
  /// In uz, this message translates to:
  /// **'Telefon raqami'**
  String get phone_login_phone_hint;

  /// No description provided for @phone_login_phone_required.
  ///
  /// In uz, this message translates to:
  /// **'Telefon raqamini kiriting'**
  String get phone_login_phone_required;

  /// No description provided for @phone_login_send_code.
  ///
  /// In uz, this message translates to:
  /// **'Kod yuborish'**
  String get phone_login_send_code;

  /// No description provided for @not_registered_title.
  ///
  /// In uz, this message translates to:
  /// **'Hali ro‘yxatdan o‘tmagansiz'**
  String get not_registered_title;

  /// No description provided for @not_registered_message.
  ///
  /// In uz, this message translates to:
  /// **'Bu telefon raqam hozircha haydovchi sifatida ro‘yxatdan o‘tmagan. Davom etish uchun YettiQanot haydovchi boti orqali ro‘yxatdan o‘ting.'**
  String get not_registered_message;

  /// No description provided for @not_registered_telegram_button.
  ///
  /// In uz, this message translates to:
  /// **'Telegram botda ro‘yxatdan o‘tish'**
  String get not_registered_telegram_button;

  /// No description provided for @not_registered_back.
  ///
  /// In uz, this message translates to:
  /// **'Orqaga'**
  String get not_registered_back;

  /// No description provided for @phone_login_code_title.
  ///
  /// In uz, this message translates to:
  /// **'Tasdiqlash kodi'**
  String get phone_login_code_title;

  /// No description provided for @phone_login_code_sent_to.
  ///
  /// In uz, this message translates to:
  /// **'Kod yuborildi: {phone}'**
  String phone_login_code_sent_to(String phone);

  /// No description provided for @phone_login_code_hint.
  ///
  /// In uz, this message translates to:
  /// **'6 raqamli kod'**
  String get phone_login_code_hint;

  /// No description provided for @phone_login_code_length.
  ///
  /// In uz, this message translates to:
  /// **'6 raqamli kodni kiriting'**
  String get phone_login_code_length;

  /// No description provided for @phone_login_verify.
  ///
  /// In uz, this message translates to:
  /// **'Tasdiqlash'**
  String get phone_login_verify;

  /// No description provided for @phone_login_code_expires.
  ///
  /// In uz, this message translates to:
  /// **'Kod amal qiladi: {time}'**
  String phone_login_code_expires(String time);

  /// No description provided for @phone_login_code_expired.
  ///
  /// In uz, this message translates to:
  /// **'Kod muddati tugadi. Kodni qayta yuboring.'**
  String get phone_login_code_expired;

  /// No description provided for @phone_login_resend.
  ///
  /// In uz, this message translates to:
  /// **'Kodni qayta yuborish'**
  String get phone_login_resend;

  /// No description provided for @phone_login_resend_in.
  ///
  /// In uz, this message translates to:
  /// **'Qayta yuborish: {time}'**
  String phone_login_resend_in(String time);

  /// No description provided for @phone_login_invalid_code.
  ///
  /// In uz, this message translates to:
  /// **'Noto‘g‘ri kod'**
  String get phone_login_invalid_code;

  /// No description provided for @phone_login_network_error.
  ///
  /// In uz, this message translates to:
  /// **'Tarmoq xatosi. Qayta urinib ko‘ring.'**
  String get phone_login_network_error;

  /// No description provided for @session_revoked_elsewhere.
  ///
  /// In uz, this message translates to:
  /// **'Boshqa qurilmadan kirildi. Bu qurilmadan chiqarildingiz.'**
  String get session_revoked_elsewhere;

  /// No description provided for @live_location_keep_app_gps.
  ///
  /// In uz, this message translates to:
  /// **'Joylashuvni yangilab turish uchun ilovani ONLAYN qoldiring, GPS ruxsatini tekshiring va safarda ilovani uzoq yopmang yoki boshqa ilovada uzoq qolmang (tizim ~90 soniyada yangilanishni kutadi).'**
  String get live_location_keep_app_gps;

  /// No description provided for @live_location_telegram_required.
  ///
  /// In uz, this message translates to:
  /// **'Bu server sozlamasida faqat Telegram «jonli lokatsiya» qabul qilinadi. Haydovchi botida jonli lokatsiyani yoqing yoki serverda HTTP joylashuvini yoqing (ENABLE_DRIVER_HTTP_LIVE_LOCATION).'**
  String get live_location_telegram_required;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['uz'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when language+script codes are specified.
  switch (locale.languageCode) {
    case 'uz':
      {
        switch (locale.scriptCode) {
          case 'Cyrl':
            return AppLocalizationsUzCyrl();
        }
        break;
      }
  }

  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'uz':
      return AppLocalizationsUz();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
