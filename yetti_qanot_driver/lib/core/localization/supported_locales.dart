import 'package:flutter/widgets.dart';

const supportedLocales = <Locale>[
  Locale('uz'),
  Locale.fromSubtags(languageCode: 'uz', scriptCode: 'Cyrl'),
];

bool isUzCyrl(Locale l) => l.languageCode == 'uz' && l.scriptCode == 'Cyrl';

