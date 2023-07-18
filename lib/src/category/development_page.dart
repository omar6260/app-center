import 'package:flutter/material.dart';
import 'package:yaru_icons/yaru_icons.dart';

import '/l10n.dart';
import 'category_page.dart';

class DevelopmentPage extends CategoryPage {
  const DevelopmentPage({super.key}) : super(category: 'development');

  static IconData icon(bool selected) => YaruIcons.wrench;
  static String label(BuildContext context) =>
      AppLocalizations.of(context).developmentPageLabel;
}