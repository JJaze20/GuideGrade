import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../core/state/app_state.dart';
import '../../../shared/widgets/app_bottom_nav.dart';
import '../../../shared/widgets/app_header_bar.dart';

/// Cloud Storage Archive — mirrors SCREENS.CLOUD_ARCHIVE.
/// Shows sync status, unsynced/cloud counts, a "Synchronize Database"
/// action, and the list of verified cloud archives.
class CloudArchiveScreen extends StatelessWidget {
  const CloudArchiveScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final appState = AppStateScope.of(context);

    return Scaffold(
      backgroundColor: AppColors.lightBg,
      appBar: const AppHeaderBar(title: 'CLOUD STORAGE ARCHIVE'),
      body: SafeArea(
        top: false,
        child: ListenableBuilder(
          listenable: appState,
          builder: (context, _) {
            final pendingSyncCount =
                appState.recentActivities.where((a) => a.isDone && !a.batch.contains('(Synced)')).length;

            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: AppColors.cardBorder),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 36,
                        height: 36,
                        decoration: const BoxDecoration(color: Color(0xFFECFDF5), shape: BoxShape.circle),
                        child: const FaIcon(FontAwesomeIcons.cloudArrowUp, size: 14, color: AppColors.primaryGreen),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('NDMU Central Hub Status', style: AppTextStyles.heading(size: 12)),
                            Text(
                              'DB Connected • Secure TLS 1.3',
                              style: AppTextStyles.body(size: 9, color: AppColors.textGray),
                            ),
                          ],
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(color: AppColors.emerald100, borderRadius: BorderRadius.circular(20)),
                        child: const Text('ONLINE', style: TextStyle(fontSize: 9, fontWeight: FontWeight.w800, color: Color(0xFF065F46))),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),

                Row(
                  children: [
                    Expanded(
                      child: _StatBox(label: 'UNSYNCED LOGS', value: '$pendingSyncCount', color: AppColors.warmRedOrange),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _StatBox(
                        label: 'CLOUD ARCHIVES',
                        value: '${appState.databaseCloudFiles.length}',
                        color: AppColors.darkNavy,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),

                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(colors: [AppColors.slate900, AppColors.slate950]),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Database Core Synchronization',
                        style: TextStyle(color: Color(0xFF6EE7B7), fontSize: 12, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Push local diagnostic tables and match against server logs.',
                        style: TextStyle(color: Colors.grey.shade300, fontSize: 10),
                      ),
                      const SizedBox(height: 8),
                      Divider(color: Colors.white.withOpacity(0.1), height: 1),
                      const SizedBox(height: 8),
                      Text(
                        'Local Sync State: ${appState.localLastUpdated}',
                        style: TextStyle(color: Colors.grey.shade400, fontSize: 9, fontFamily: 'monospace'),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Database State: ${appState.databaseLastSynced}',
                        style: TextStyle(color: Colors.grey.shade400, fontSize: 9, fontFamily: 'monospace'),
                      ),
                      const SizedBox(height: 10),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          onPressed: () {
                            appState.syncLocalToDatabase();
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Database synchronized successfully!')),
                            );
                          },
                          icon: const FaIcon(FontAwesomeIcons.arrowsRotate, size: 13),
                          label: const Text('SYNCHRONIZE DATABASE'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.primaryGreen,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 11),
                            textStyle: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),

                Row(
                  children: [
                    const FaIcon(FontAwesomeIcons.server, size: 11, color: AppColors.primaryGreen),
                    const SizedBox(width: 6),
                    Text('Verified Cloud Database Archives', style: AppTextStyles.heading(size: 11.5)),
                  ],
                ),
                const SizedBox(height: 8),
                ...appState.databaseCloudFiles.map((cf) => Container(
                      margin: const EdgeInsets.only(bottom: 6),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: AppColors.cardBorder),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(cf.name, style: AppTextStyles.body(size: 10.5, weight: FontWeight.w700)),
                                Text(
                                  '${cf.timestamp} • Code: ${cf.code} • N=${cf.total}',
                                  style: AppTextStyles.body(size: 8.5, color: AppColors.textGray),
                                ),
                              ],
                            ),
                          ),
                          const FaIcon(FontAwesomeIcons.cloud, size: 13, color: AppColors.primaryGreen),
                        ],
                      ),
                    )),
              ],
            );
          },
        ),
      ),
      bottomNavigationBar: const AppBottomNav(activeTab: 'cloud'),
    );
  }
}

class _StatBox extends StatelessWidget {
  final String label;
  final String value;
  final Color color;

  const _StatBox({required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.cardBorder),
      ),
      child: Column(
        children: [
          Text(label, style: const TextStyle(fontSize: 8.5, fontWeight: FontWeight.w800, color: AppColors.textGray)),
          const SizedBox(height: 2),
          Text(value, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: color, fontFamily: 'monospace')),
        ],
      ),
    );
  }
}
