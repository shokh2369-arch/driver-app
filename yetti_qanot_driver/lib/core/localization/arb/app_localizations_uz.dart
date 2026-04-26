// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Uzbek (`uz`).
class AppLocalizationsUz extends AppLocalizations {
  AppLocalizationsUz([String locale = 'uz']) : super(locale);

  @override
  String get online => 'Online';

  @override
  String get offline => 'Offline';

  @override
  String get start_trip => 'Safarni boshlash';

  @override
  String get finish_trip => 'Safarni tugatish';

  @override
  String get cancel_trip => 'Safarni bekor qilish';

  @override
  String get arrived => 'Yetib keldim';

  @override
  String get to_pickup => 'Mijozga yo’lda';

  @override
  String get trip_status_ready_to_start => 'Safarni boshlash mumkin';

  @override
  String get trip_arrived_need_closer =>
      'Mijozga ~100 m yaqin bo‘ling — «Yetib keldim» ochiladi.';

  @override
  String get unfinished_trip_title => 'Tugallanmagan safar';

  @override
  String get unfinished_trip_phase_started => 'Safar davom etmoqda';

  @override
  String get trip_completes_on_server_hint =>
      'Safar tugashi haydovchi ilovasidan emas — tizim holatni yangilaydi.';

  @override
  String get trip_finish_hint =>
      'Tugatish buyurtmani yakunlaydi va holat serverga yuboriladi.';

  @override
  String get trip_completed_dialog_title => 'Safar tugadi';

  @override
  String get trip_completed_ok => 'Yaxshi';

  @override
  String get unfinished_trip_continue => 'Davom etish';

  @override
  String get trip_plan_not_found => 'Reja topilmadi';

  @override
  String get enable_location => 'Lokatsiyani yoqing';

  @override
  String get allow_location => 'Lokatsiyaga ruxsat bering';

  @override
  String get balance => 'Balans';

  @override
  String get promo_balance => 'Promo balans';

  @override
  String get cash_balance => 'Naqd balans';

  @override
  String get accept => 'Qabul qilish';

  @override
  String get auto_offer => 'Avto-taklif';

  @override
  String get orders => 'Buyurtmalar';

  @override
  String get trip_history_title => 'Safarlar tarixi';

  @override
  String get trip_history_empty =>
      'Hozircha yakunlangan safarlar yo‘q. Ro‘yxat serverdan yuklanadi.';

  @override
  String get available_requests_title => 'Mavjud buyurtmalar';

  @override
  String get available_requests_empty =>
      'Hozircha navbatdagi buyurtmalar yo‘q.';

  @override
  String get available_requests_no_api => 'Server manzili sozlanmagan.';

  @override
  String get available_requests_load_error =>
      'Ro‘yxatni yuklab bo‘lmadi. Internetni tekshiring.';

  @override
  String get dist_to_pickup => 'Mijozgacha';

  @override
  String get trip_route_km => 'Safar';

  @override
  String get from_place => 'Qayerdan';

  @override
  String get to_place => 'Qayerga';

  @override
  String get parking_off => 'To‘xtashda emas';

  @override
  String get commission_banner => 'Buyurtmadan 5%';

  @override
  String get settings => 'Sozlamalar';

  @override
  String get theme_title => 'Ko‘rinish';

  @override
  String get theme_system => 'Tizim';

  @override
  String get theme_light => 'Yorug‘';

  @override
  String get theme_dark => 'To‘q';

  @override
  String get language_title => 'Til';

  @override
  String get language_option_latin => 'Oʻzbekcha';

  @override
  String get language_option_cyrillic => 'Ўзбекча';

  @override
  String get language_use_device => 'Qurilma tili';

  @override
  String get referral_link_label => 'Referal havolasi';

  @override
  String get copy_action => 'Nusxa olish';

  @override
  String get copied_to_clipboard => 'Havola buferga nusxalandi';

  @override
  String get sign_out => 'Chiqish';

  @override
  String get call => 'Qo‘ng‘iroq';

  @override
  String get trip_customer_label => 'Mijoz';

  @override
  String get trip_price_label => 'Narx';

  @override
  String get trip_distance_label => 'Masofa';

  @override
  String trip_map_stats_minutes(int minutes) {
    return '$minutes daqiqa';
  }

  @override
  String get driver_id_title => 'Haydovchi ID';

  @override
  String get driver_id_subtitle =>
      'Ichki users.id yoki Telegram telegram_id (tasdiqlangan haydovchi). Admin / bot bilan bir xil.';

  @override
  String get driver_id_hint => 'Masalan: 123456789';

  @override
  String get driver_id_save => 'Saqlash';

  @override
  String get driver_id_error_empty => 'ID kiritilmagan';

  @override
  String get driver_id_error_digits =>
      'Faqat raqamlar: ichki users.id yoki Telegram ID';

  @override
  String get legal_acceptance_title => 'Huquqiy hujjatlar';

  @override
  String get legal_acceptance_subtitle =>
      'Davom etishdan oldin quyidagi shartlarni qabul qiling.';

  @override
  String get legal_acceptance_confirm => 'Qabul qilaman';

  @override
  String get retry => 'Qayta urinish';

  @override
  String get offline_api_failed =>
      'Offline rejimga o‘tib bo‘lmadi. Internetni tekshirib, qayta urinib ko‘ring.';

  @override
  String get phone_login_title => 'Kirish';

  @override
  String get phone_login_subtitle =>
      'Telefon raqamingizni kiriting — SMS orqali kod yuboramiz.';

  @override
  String get phone_login_phone_hint => 'Telefon raqami';

  @override
  String get phone_login_phone_required => 'Telefon raqamini kiriting';

  @override
  String get phone_login_send_code => 'Kod yuborish';

  @override
  String get not_registered_title => 'Hali ro‘yxatdan o‘tmagansiz';

  @override
  String get not_registered_message =>
      'Bu telefon raqam hozircha haydovchi sifatida ro‘yxatdan o‘tmagan. Davom etish uchun YettiQanot haydovchi boti orqali ro‘yxatdan o‘ting.';

  @override
  String get not_registered_telegram_button =>
      'Telegram botda ro‘yxatdan o‘tish';

  @override
  String get not_registered_back => 'Orqaga';

  @override
  String get phone_login_code_title => 'Tasdiqlash kodi';

  @override
  String phone_login_code_sent_to(String phone) {
    return 'Kod yuborildi: $phone';
  }

  @override
  String get phone_login_code_hint => '6 raqamli kod';

  @override
  String get phone_login_code_length => '6 raqamli kodni kiriting';

  @override
  String get phone_login_verify => 'Tasdiqlash';

  @override
  String phone_login_code_expires(String time) {
    return 'Kod amal qiladi: $time';
  }

  @override
  String get phone_login_code_expired =>
      'Kod muddati tugadi. Kodni qayta yuboring.';

  @override
  String get phone_login_resend => 'Kodni qayta yuborish';

  @override
  String phone_login_resend_in(String time) {
    return 'Qayta yuborish: $time';
  }

  @override
  String get phone_login_invalid_code => 'Noto‘g‘ri kod';

  @override
  String get phone_login_network_error =>
      'Tarmoq xatosi. Qayta urinib ko‘ring.';

  @override
  String get session_revoked_elsewhere =>
      'Boshqa qurilmadan kirildi. Bu qurilmadan chiqarildingiz.';

  @override
  String get live_location_keep_app_gps =>
      'Joylashuvni yangilab turish uchun ilovani ONLAYN qoldiring, GPS ruxsatini tekshiring va safarda ilovani uzoq yopmang yoki boshqa ilovada uzoq qolmang (tizim ~90 soniyada yangilanishni kutadi).';

  @override
  String get live_location_telegram_required =>
      'Bu server sozlamasida faqat Telegram «jonli lokatsiya» qabul qilinadi. Haydovchi botida jonli lokatsiyani yoqing yoki serverda HTTP joylashuvini yoqing (ENABLE_DRIVER_HTTP_LIVE_LOCATION).';
}

/// The translations for Uzbek, using the Cyrillic script (`uz_Cyrl`).
class AppLocalizationsUzCyrl extends AppLocalizationsUz {
  AppLocalizationsUzCyrl() : super('uz_Cyrl');

  @override
  String get online => 'Онлайн';

  @override
  String get offline => 'Оффлайн';

  @override
  String get start_trip => 'Сафарни бошлаш';

  @override
  String get finish_trip => 'Сафарни тугатиш';

  @override
  String get cancel_trip => 'Сафарни бекор қилиш';

  @override
  String get arrived => 'Етиб келдим';

  @override
  String get to_pickup => 'Мижозга йўлда';

  @override
  String get trip_status_ready_to_start => 'Сафарни бошлаш мумкин';

  @override
  String get trip_arrived_need_closer =>
      'Мижозга ~100 м яқин бўлинг — «Етиб келдим» очилади.';

  @override
  String get unfinished_trip_title => 'Тугалланмаган сафар';

  @override
  String get unfinished_trip_phase_started => 'Сафар давом этмоқда';

  @override
  String get trip_completes_on_server_hint =>
      'Сафар тугаши ҳайдовчи иловасидан эмас — тизим ҳолатни янгилайди.';

  @override
  String get trip_finish_hint =>
      'Тугаш буюртмани якунлайди ва ҳолат серверга юборилади.';

  @override
  String get trip_completed_dialog_title => 'Сафар тугади';

  @override
  String get trip_completed_ok => 'Яхши';

  @override
  String get unfinished_trip_continue => 'Давом этиш';

  @override
  String get trip_plan_not_found => 'Режа топилмади';

  @override
  String get enable_location => 'Локацияни ёқинг';

  @override
  String get allow_location => 'Локацияга рухсат беринг';

  @override
  String get balance => 'Баланс';

  @override
  String get promo_balance => 'Промо баланс';

  @override
  String get cash_balance => 'Нақд баланс';

  @override
  String get accept => 'Қабул қилиш';

  @override
  String get auto_offer => 'Авто-таклиф';

  @override
  String get orders => 'Буюртмалар';

  @override
  String get trip_history_title => 'Сафарлар тарихи';

  @override
  String get trip_history_empty =>
      'Ҳозирча якунланган сафарлар йўқ. Рўйхат сервердан юкланади.';

  @override
  String get available_requests_title => 'Мавжуд буюртмалар';

  @override
  String get available_requests_empty => 'Ҳозирча навбатдаги буюртмалар йўқ.';

  @override
  String get available_requests_no_api => 'Сервер манзили созланмаган.';

  @override
  String get available_requests_load_error =>
      'Рўйхатни юклаб бўлмади. Интернетни текширинг.';

  @override
  String get dist_to_pickup => 'Мижозгача';

  @override
  String get trip_route_km => 'Сафар';

  @override
  String get from_place => 'Қаердан';

  @override
  String get to_place => 'Қаерга';

  @override
  String get parking_off => 'Тўхташда эмас';

  @override
  String get commission_banner => 'Буюртмадан 5%';

  @override
  String get settings => 'Созламалар';

  @override
  String get theme_title => 'Кўриниш';

  @override
  String get theme_system => 'Тизим';

  @override
  String get theme_light => 'Ёруғ';

  @override
  String get theme_dark => 'Тўқ';

  @override
  String get language_title => 'Тил';

  @override
  String get language_option_latin => 'Oʻzbekcha';

  @override
  String get language_option_cyrillic => 'Ўзбекча';

  @override
  String get language_use_device => 'Қурилма тили';

  @override
  String get referral_link_label => 'Реферал ҳаволаси';

  @override
  String get copy_action => 'Нусха олиш';

  @override
  String get copied_to_clipboard => 'Ҳавола буферга нусхаланди';

  @override
  String get sign_out => 'Чиқиш';

  @override
  String get call => 'Қўнғироқ';

  @override
  String get trip_customer_label => 'Мижоз';

  @override
  String get trip_price_label => 'Нарх';

  @override
  String get trip_distance_label => 'Масофа';

  @override
  String trip_map_stats_minutes(int minutes) {
    return '$minutes дақиқа';
  }

  @override
  String get driver_id_title => 'Ҳайдовчи ID';

  @override
  String get driver_id_subtitle =>
      'Ички users.id ёки Telegram telegram_id (тасдиқланган ҳайдовчи). Админ / бот билан бир хил.';

  @override
  String get driver_id_hint => 'Масалан: 123456789';

  @override
  String get driver_id_save => 'Сақлаш';

  @override
  String get driver_id_error_empty => 'ID киритилмаган';

  @override
  String get driver_id_error_digits =>
      'Фақат рақамлар: ички users.id ёки Telegram ID';

  @override
  String get legal_acceptance_title => 'Ҳуқуқий ҳужжатлар';

  @override
  String get legal_acceptance_subtitle =>
      'Давом этишдан олдин қуйидаги шартларни қабул қилинг.';

  @override
  String get legal_acceptance_confirm => 'Қабул қиламан';

  @override
  String get retry => 'Қайта уриниш';

  @override
  String get offline_api_failed =>
      'Оффлайн режимга ўтиб бўлмади. Интернетни текшириб, қайта уриниб кўринг.';

  @override
  String get phone_login_title => 'Кириш';

  @override
  String get phone_login_subtitle =>
      'Телефон рақамингизни киритинг — SMS орқали код юборамиз.';

  @override
  String get phone_login_phone_hint => 'Телефон рақами';

  @override
  String get phone_login_phone_required => 'Телефон рақамини киритинг';

  @override
  String get phone_login_send_code => 'Код юбориш';

  @override
  String get not_registered_title => 'Ҳали рўйхатдан ўтмагансиз';

  @override
  String get not_registered_message =>
      'Бу телефон рақам ҳозирча ҳайдовчи сифатида рўйхатдан ўтмаган. Давом этиш учун YettiQanot ҳайдовчи боти орқали рўйхатдан ўтинг.';

  @override
  String get not_registered_telegram_button => 'Telegram ботда рўйхатдан ўтиш';

  @override
  String get not_registered_back => 'Орқага';

  @override
  String get phone_login_code_title => 'Тасдиқлаш коди';

  @override
  String phone_login_code_sent_to(String phone) {
    return 'Код юборилди: $phone';
  }

  @override
  String get phone_login_code_hint => '6 рақамли код';

  @override
  String get phone_login_code_length => '6 рақамли кодни киритинг';

  @override
  String get phone_login_verify => 'Тасдиқлаш';

  @override
  String phone_login_code_expires(String time) {
    return 'Код амал қилади: $time';
  }

  @override
  String get phone_login_code_expired =>
      'Код муддати тугади. Кодни қайта юборинг.';

  @override
  String get phone_login_resend => 'Кодни қайта юбориш';

  @override
  String phone_login_resend_in(String time) {
    return 'Қайта юбориш: $time';
  }

  @override
  String get phone_login_invalid_code => 'Нотўғри код';

  @override
  String get phone_login_network_error => 'Тармоқ хатоси. Қайта уриниб кўринг.';

  @override
  String get session_revoked_elsewhere =>
      'Бошқа қурилмадан кирилди. Бу қурилмадан чиқарилдингиз.';

  @override
  String get live_location_keep_app_gps =>
      'Жойлашувни янгилаб туриш учун иловани ОНЛАЙН қолдиринг, GPS рухсатини текширинг ва сафарда иловани узоқ ёпманг ёки бошқа иловада узоқ қолманг (тизим ~90 сонияда янгиланишни кутади).';

  @override
  String get live_location_telegram_required =>
      'Бу сервер созлашида фақат Telegram «жонли локация» қабул қилинади. Ҳайдовчи ботида жонли локацияни ёқинг ёки серверда HTTP жойлашувини ёқинг (ENABLE_DRIVER_HTTP_LIVE_LOCATION).';
}
