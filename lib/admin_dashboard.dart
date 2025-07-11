// ignore_for_file: use_build_context_synchronously

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:open_filex/open_filex.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:dropdown_search/dropdown_search.dart';
import 'package:syncfusion_flutter_xlsio/xlsio.dart' as xlsio;
import 'login.dart';

class AttendanceRecord {
  final String name;
  final String psName;
  final DateTime checkInTime;
  final DateTime? checkOutTime;
  final String checkInLocation;
  final String? checkOutLocation;
  final String userId;
  AttendanceRecord({
    required this.name,
    required this.psName,
    required this.checkInTime,
    this.checkOutTime,
    required this.checkInLocation,
    this.checkOutLocation,
    required this.userId,
  });
  Duration get totalTimeCheckedIn => (checkOutTime ?? DateTime.now()).difference(checkInTime);
}

enum SortFilter { person, week, month, year, all }

class AdminDashboard extends StatefulWidget {
  const AdminDashboard({super.key});
  @override
  State<AdminDashboard> createState() => _AdminDashboardState();
}

class _AdminDashboardState extends State<AdminDashboard> {
  SortFilter _selectedFilter = SortFilter.all;
  List<AttendanceRecord> allRecords = [];
  bool _isLoading = true;

  // FILTER STATE
  List<String>? _selectedPsNames; // Changed to List<String>
  DateTime? _selectedDay;
  DateTimeRange? _selectedDateRange;
  int? _selectedMonth;
  int? _selectedYear;

  @override
  void initState() {
    super.initState();
    _fetchAttendanceData();
  }

  Future<void> _fetchAttendanceData() async {
    setState(() {
      _isLoading = true;
      allRecords = [];
    });
    try {
      final users = await FirebaseFirestore.instance.collection('Users').get();
      List<AttendanceRecord> fetchedRecords = [];
      for (final user in users.docs) {
        final attendance = await FirebaseFirestore.instance
            .collection('Users')
            .doc(user.id)
            .collection('attendance')
            .orderBy('checkInTime', descending: true)
            .get();
        final String psName = user.data()['psName'] as String? ?? 'Unknown PS';
        for (final recordDoc in attendance.docs) {
          final data = recordDoc.data();
          final AttendanceRecord record = AttendanceRecord(
            name: data['Name'] as String? ?? 'Unknown',
            psName: psName,
            checkInTime: (data['checkInTime'] as Timestamp).toDate(),
            checkOutTime: (data['checkOutTime'] as Timestamp?)?.toDate(),
            checkInLocation: data['checkInLocation'] as String? ?? 'N/A',
            checkOutLocation: data['checkOutLocation'] as String?,
            userId: user.id,
          );
          fetchedRecords.add(record);
        }
      }
      setState(() {
        allRecords = fetchedRecords;
        _isLoading = false;
      });
    } catch (e) {
      setState(() => _isLoading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to load attendance data: $e')),
      );
    }
  }

  String _formatDateTime(DateTime dateTime) {
    return '${dateTime.year}-${_twoDigits(dateTime.month)}-${_twoDigits(dateTime.day)} '
        '${_twoDigits(dateTime.hour)}:${_twoDigits(dateTime.minute)}:${_twoDigits(dateTime.second)}';
  }

  String _twoDigits(int n) => n.toString().padLeft(2, '0');

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);
    return '${twoDigits(hours)}h ${twoDigits(minutes)}m ${twoDigits(seconds)}s';
  }

  List<String> get _allPsNames {
    final set = <String>{};
    for (final record in allRecords) {
      set.add(record.psName);
    }
    final list = set.toList();
    list.sort();
    return list;
  }

  List<AttendanceRecord> get _filteredRecords {
    List<AttendanceRecord> records = List.from(allRecords);

    // Apply date/time filters
    if (_selectedDay != null) {
      records = records
          .where((r) =>
              r.checkInTime.year == _selectedDay!.year &&
              r.checkInTime.month == _selectedDay!.month &&
              r.checkInTime.day == _selectedDay!.day)
          .toList();
    } else if (_selectedDateRange != null) {
      records = records
          .where((r) =>
              !r.checkInTime.isBefore(_selectedDateRange!.start) &&
              !r.checkInTime.isAfter(_selectedDateRange!.end))
          .toList();
    } else if (_selectedMonth != null || _selectedYear != null) {
      records = records.where((r) {
        final matchMonth = _selectedMonth == null || r.checkInTime.month == _selectedMonth;
        final matchYear = _selectedYear == null || r.checkInTime.year == _selectedYear;
        return matchMonth && matchYear;
      }).toList();
    }

    // Apply Police Station filter
    if (_selectedPsNames != null && _selectedPsNames!.isNotEmpty) {
      records = records.where((r) => _selectedPsNames!.contains(r.psName)).toList();
    }

    // Apply general SortFilter
    final now = DateTime.now();
    switch (_selectedFilter) {
      case SortFilter.all:
        break;
      case SortFilter.person:
        records.sort((a, b) {
          int psComp = a.psName.compareTo(b.psName);
          if (psComp != 0) return psComp;
          return a.name.compareTo(b.name);
        });
        break;
      case SortFilter.week:
        records = records.where((record) {
          return record.checkInTime.isAfter(now.subtract(const Duration(days: 7)));
        }).toList();
        break;
      case SortFilter.month:
        records = records.where((record) {
          return record.checkInTime.year == now.year && record.checkInTime.month == now.month;
        }).toList();
        break;
      case SortFilter.year:
        records = records.where((record) {
          return record.checkInTime.year == now.year;
        }).toList();
        break;
    }
    return records;
  }

  // --- ANALYTICS FUNCTIONS (now accept a list of records) ---
  int getCheckedInCount(List<AttendanceRecord> records) =>
      records.where((r) => r.checkOutTime == null).length;
  int getTotalUniqueMarshals(List<AttendanceRecord> records) =>
      records.map((r) => r.name).toSet().length;

  Map<String, Duration> getTotalHoursPerMarshal(List<AttendanceRecord> records) {
    final map = <String, Duration>{};
    for (final record in records) {
      map.update(
        record.name,
        (d) => d + record.totalTimeCheckedIn,
        ifAbsent: () => record.totalTimeCheckedIn,
      );
    }
    return map;
  }

  Map<String, String> getMarshalPsNames(List<AttendanceRecord> records) {
    final map = <String, String>{};
    for (final record in records) {
      map[record.name] = record.psName;
    }
    return map;
  }

  Widget _buildFilters() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: DropdownSearch<String>.multiSelection(
              items: (String? filter, _) async {
                if (filter == null || filter.isEmpty) return _allPsNames;
                return _allPsNames
                    .where((ps) => ps.toLowerCase().contains(filter.toLowerCase()))
                    .toList();
              },
              selectedItems: _selectedPsNames ?? [],
              onChanged: (psList) => setState(() => _selectedPsNames = psList),
              decoratorProps: const DropDownDecoratorProps(
                decoration: InputDecoration(
                  labelText: "Police Station(s)",
                  contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  border: OutlineInputBorder(),
                ),
              ),
              popupProps: const PopupPropsMultiSelection.menu(
                fit: FlexFit.loose,
                searchFieldProps: TextFieldProps(
                  decoration: InputDecoration(
                    labelText: "Search Police Station",
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              suffixProps: DropdownSuffixProps(
                clearButtonProps: const ClearButtonProps(isVisible: true),
                dropdownButtonProps: const DropdownButtonProps(isVisible: true),
              )),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            children: [
              const Text('Day:'),
              const SizedBox(width: 8),
              TextButton(
                onPressed: () async {
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: _selectedDay ?? DateTime.now(),
                    firstDate: DateTime(2020),
                    lastDate: DateTime.now(),
                  );
                  if (picked != null) setState(() => _selectedDay = picked);
                },
                child: Text(_selectedDay == null
                    ? 'Select Day'
                    : '${_selectedDay!.year}-${_selectedDay!.month.toString().padLeft(2, '0')}-${_selectedDay!.day.toString().padLeft(2, '0')}'),
              ),
              if (_selectedDay != null)
                IconButton(
                  icon: const Icon(Icons.clear),
                  onPressed: () => setState(() => _selectedDay = null),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            children: [
              const Text('Date Range:'),
              const SizedBox(width: 8),
              TextButton(
                onPressed: () async {
                  final picked = await showDateRangePicker(
                    context: context,
                    firstDate: DateTime(2020),
                    lastDate: DateTime.now(),
                    initialDateRange: _selectedDateRange,
                  );
                  if (picked != null) setState(() => _selectedDateRange = picked);
                },
                child: Text(_selectedDateRange == null
                    ? 'Select Range'
                    : '${_selectedDateRange!.start.year}-${_selectedDateRange!.start.month.toString().padLeft(2, '0')}-${_selectedDateRange!.start.day.toString().padLeft(2, '0')}'
                        ' to '
                        '${_selectedDateRange!.end.year}-${_selectedDateRange!.end.month.toString().padLeft(2, '0')}-${_selectedDateRange!.end.day.toString().padLeft(2, '0')}'),
              ),
              if (_selectedDateRange != null)
                IconButton(
                  icon: const Icon(Icons.clear),
                  onPressed: () => setState(() => _selectedDateRange = null),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            children: [
              const Text('Month:'),
              const SizedBox(width: 8),
              DropdownButton<int>(
                value: _selectedMonth,
                hint: const Text('Select Month'),
                items: List.generate(12, (i) => i + 1)
                    .map((m) =>
                        DropdownMenuItem(value: m, child: Text(m.toString().padLeft(2, '0'))))
                    .toList(),
                onChanged: (m) => setState(() => _selectedMonth = m),
              ),
              const SizedBox(width: 8),
              DropdownButton<int>(
                value: _selectedYear,
                hint: const Text('Year'),
                items: [2025, 2026, 2027]
                    .map((y) => DropdownMenuItem(value: y, child: Text(y.toString())))
                    .toList(),
                onChanged: (y) => setState(() => _selectedYear = y),
              ),
              if (_selectedMonth != null || _selectedYear != null)
                IconButton(
                  icon: const Icon(Icons.clear),
                  onPressed: () => setState(() {
                    _selectedMonth = null;
                    _selectedYear = null;
                  }),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Builder(
            builder: (context) {
              String filterSummary = '';
              if (_selectedPsNames != null && _selectedPsNames!.isNotEmpty) {
                filterSummary += 'PS: ${_selectedPsNames!.join(', ')}  ';
              }
              if (_selectedDay != null) {
                filterSummary +=
                    'Day: ${_selectedDay!.year}-${_selectedDay!.month.toString().padLeft(2, '0')}-${_selectedDay!.day.toString().padLeft(2, '0')}  ';
              }
              if (_selectedDateRange != null) {
                filterSummary +=
                    'Range: ${_selectedDateRange!.start.year}-${_selectedDateRange!.start.month.toString().padLeft(2, '0')}-${_selectedDateRange!.start.day.toString().padLeft(2, '0')}'
                    ' to '
                    '${_selectedDateRange!.end.year}-${_selectedDateRange!.end.month.toString().padLeft(2, '0')}-${_selectedDateRange!.end.day.toString().padLeft(2, '0')}  ';
              }
              if (_selectedMonth != null) {
                filterSummary += 'Month: ${_selectedMonth.toString().padLeft(2, '0')}  ';
              }
              if (_selectedYear != null) filterSummary += 'Year: $_selectedYear  ';
              return filterSummary.isNotEmpty
                  ? Text('Active Filters: $filterSummary',
                      style: const TextStyle(fontWeight: FontWeight.bold))
                  : const SizedBox.shrink();
            },
          ),
        ),
      ],
    );
  }

  List<PieChartSectionData> _getPieChartSections(int checkedIn, int totalUnique) {
    final double checkedInPercentage = totalUnique > 0 ? (checkedIn / totalUnique) * 100 : 0;
    final double checkedOutPercentage =
        totalUnique > 0 ? ((totalUnique - checkedIn) / totalUnique) * 100 : 0;
    return [
      PieChartSectionData(
        color: const Color.fromARGB(255, 14, 242, 41),
        value: checkedInPercentage,
        title: '${checkedInPercentage.toStringAsFixed(1)}%',
        radius: 50,
        titleStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
      ),
      PieChartSectionData(
        color: const Color.fromARGB(255, 255, 17, 0),
        value: checkedOutPercentage,
        title: '${checkedOutPercentage.toStringAsFixed(1)}%',
        radius: 50,
        titleStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
      ),
    ];
  }

  Widget _buildLegend(Color color, String text) {
    return Row(
      children: [
        Container(
          width: 16,
          height: 16,
          color: color,
        ),
        const SizedBox(width: 5),
        Text(text),
      ],
    );
  }

  List<BarChartGroupData> _getBarGroups(
      Map<String, Duration> totalHoursPerMarshal, Map<String, String> marshalPsNames) {
    final List<String> marshalNames = totalHoursPerMarshal.keys.toList();
    marshalNames.sort((a, b) {
      int psComp = (marshalPsNames[a] ?? '').compareTo(marshalPsNames[b] ?? '');
      if (psComp != 0) return psComp;
      return a.compareTo(b);
    });
    return marshalNames.asMap().entries.map((entry) {
      int index = entry.key;
      String name = entry.value;
      double totalHours = totalHoursPerMarshal[name]?.inMinutes.toDouble() ?? 0;
      totalHours = totalHours / 60;
      return BarChartGroupData(
        x: index,
        barRods: [
          BarChartRodData(
            toY: double.parse(totalHours.toStringAsFixed(2)),
            color: const Color.fromARGB(255, 25, 36, 159),
            width: 16,
            borderRadius: BorderRadius.circular(4),
          ),
        ],
        showingTooltipIndicators: [0],
      );
    }).toList();
  }

  Widget _getBottomTitles(
      double value, TitleMeta meta, List<String> marshalNames, Map<String, String> marshalPsNames) {
    String text = '';
    if (value.toInt() >= 0 && value.toInt() < marshalNames.length) {
      text = marshalNames[value.toInt()];
      final ps = marshalPsNames[text] ?? '';
      text = '$text\n($ps)';
    }
    return SideTitleWidget(
      meta: meta,
      space: 10,
      child: Text(text, style: const TextStyle(fontSize: 10)),
    );
  }

  Widget _getLeftTitles(double value, TitleMeta meta) {
    if (value == meta.max || value == 0) return Container();
    return SideTitleWidget(
      meta: meta,
      space: 10,
      child: Text('${value.toStringAsFixed(2)}h', style: const TextStyle(fontSize: 10)),
    );
  }

  double _getMaxYValue(Map<String, Duration> totalHoursPerMarshal) {
    if (totalHoursPerMarshal.isEmpty) return 10;
    double maxHours = 0;
    for (final duration in totalHoursPerMarshal.values) {
      double hours = duration.inMinutes / 60;
      if (hours > maxHours) maxHours = hours;
    }
    return (maxHours * 1.2).ceilToDouble();
  }

  // --- EXPORT TO EXCEL ---
  Future<void> exportToExcelWithCharts(List<AttendanceRecord> records, BuildContext context) async {
    try {
      PermissionStatus status;
      if (Platform.isAndroid) {
        status = await Permission.manageExternalStorage.request();
      } else {
        status = PermissionStatus.granted;
      }
      if (!status.isGranted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Storage permission not granted. Cannot export.')),
        );
        return;
      }

      // Screenshots are no longer captured or added to Excel

      // Create Excel workbook
      final workbook = xlsio.Workbook();
      final sheet = workbook.worksheets[0];

      // Add attendance data
      sheet.getRangeByName('A1').setText('Name');
      sheet.getRangeByName('B1').setText('PS Name');
      sheet.getRangeByName('C1').setText('Check-in Time');
      sheet.getRangeByName('D1').setText('Check-out Time');
      sheet.getRangeByName('E1').setText('Total Time');
      sheet.getRangeByName('F1').setText('Check-in Location');
      sheet.getRangeByName('G1').setText('Check-out Location');

      int row = 2;
      for (final record in records) {
        sheet.getRangeByName('A$row').setText(record.name);
        sheet.getRangeByName('B$row').setText(record.psName);
        sheet.getRangeByName('C$row').setText(_formatDateTime(record.checkInTime));
        sheet.getRangeByName('D$row').setText(record.checkOutTime != null
            ? _formatDateTime(record.checkOutTime!)
            : 'Still checked in');
        sheet.getRangeByName('E$row').setText(_formatDuration(record.totalTimeCheckedIn));
        sheet.getRangeByName('F$row').setText(record.checkInLocation);
        sheet.getRangeByName('G$row').setText(record.checkOutLocation ?? 'N/A');
        row++;
      }

      final bytes = workbook.saveAsStream();
      workbook.dispose();

      Directory? directory;
      String? savePath;
      if (Platform.isAndroid) {
        directory = await getExternalStorageDirectory();
        if (directory != null) {
          final List<String> paths = directory.path.split('/');
          String newPath = '';
          for (int x = 1; x < paths.length; x++) {
            String folder = paths[x];
            if (folder == 'Android') break;
            newPath += '/$folder';
          }
          newPath = '$newPath/Download';
          directory = Directory(newPath);
        }
        if (directory == null || !await directory.exists()) {
          directory = await getApplicationDocumentsDirectory();
        }
      } else {
        directory = await getApplicationDocumentsDirectory();
      }
      savePath = directory.path;

      final fileName = 'attendance_export_${DateTime.now().millisecondsSinceEpoch}.xlsx';
      final file = File('$savePath/$fileName');
      await file.writeAsBytes(bytes, flush: true);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Excel exported to $savePath/$fileName'),
          action: SnackBarAction(
            label: 'Open',
            onPressed: () async {
              final result = await OpenFilex.open(file.path);
              if (result.type != ResultType.done) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Could not open file: ${result.message}')),
                );
              }
            },
          ),
        ),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error exporting Excel: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final List<AttendanceRecord> currentFilteredRecords = _filteredRecords;

    final Map<String, List<AttendanceRecord>> recordsByPs = {};
    // If _selectedPsNames is not empty, iterate through selected PS names.
    // Otherwise, find all unique PS names from the currentFilteredRecords (which already applies date/time filters)
    // to display overall data grouped by PS.
    final List<String> psNamesToDisplay = (_selectedPsNames != null && _selectedPsNames!.isNotEmpty)
        ? _selectedPsNames!
        : currentFilteredRecords.map((r) => r.psName).toSet().toList();

    for (final psName in psNamesToDisplay) {
      recordsByPs[psName] =
          currentFilteredRecords.where((record) => record.psName == psName).toList();
    }

    final sortedPsNames = recordsByPs.keys.toList()..sort();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Admin Dashboard'),
        actions: [
          IconButton(
            icon: const Icon(Icons.person_add),
            tooltip: 'Create User',
            onPressed: _showCreateUserDialog,
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _fetchAttendanceData,
            tooltip: 'Refresh Data',
          ),
          IconButton(
            icon: const Icon(Icons.download),
            onPressed: () => exportToExcelWithCharts(currentFilteredRecords, context),
            tooltip: 'Export to Excel',
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Logout',
            onPressed: _logout,
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              child: Column(
                children: [
                  _buildFilters(),
                  if (sortedPsNames.isEmpty)
                    const Center(
                      child: Padding(
                        padding: EdgeInsets.all(16.0),
                        child: Text(
                            'No attendance records found for the selected filters or police stations.'),
                      ),
                    ),
                  ...sortedPsNames.map((psName) {
                    final psRecords = recordsByPs[psName]!;
                    final psCheckedInCount = getCheckedInCount(psRecords);
                    final psTotalUniqueMarshals = getTotalUniqueMarshals(psRecords);
                    final psTotalHoursPerMarshal = getTotalHoursPerMarshal(psRecords);
                    final psMarshalNames = psTotalHoursPerMarshal.keys.toList()
                      ..sort((a, b) {
                        int marshalPsComp = (getMarshalPsNames(psRecords)[a] ?? '')
                            .compareTo(getMarshalPsNames(psRecords)[b] ?? '');
                        if (marshalPsComp != 0) return marshalPsComp;
                        return a.compareTo(b);
                      });
                    final psMarshalPsNames = getMarshalPsNames(psRecords);
                    final psMaxYValue = _getMaxYValue(psTotalHoursPerMarshal);

                    return Padding(
                      padding: const EdgeInsets.all(8.0),
                      child: Card(
                        elevation: 4,
                        child: Padding(
                          padding: const EdgeInsets.all(16.0),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Attendance Overview for ${psName.isEmpty ? 'Unknown PS' : psName}',
                                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                              ),
                              const SizedBox(height: 10),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Text('Marshals Checked In: $psCheckedInCount'),
                                  Text('Total Marshals: $psTotalUniqueMarshals'),
                                ],
                              ),
                              const SizedBox(height: 15),
                              if (psTotalUniqueMarshals > 0)
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text('Check-in Status',
                                        style: TextStyle(fontWeight: FontWeight.bold)),
                                    const SizedBox(height: 8),
                                    SizedBox(
                                      height: 200,
                                      child: PieChart(
                                        PieChartData(
                                          sections: _getPieChartSections(
                                              psCheckedInCount, psTotalUniqueMarshals),
                                          centerSpaceRadius: 40,
                                          sectionsSpace: 2,
                                          borderData: FlBorderData(show: false),
                                        ),
                                      ),
                                    ),
                                    Row(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        _buildLegend(Colors.green, 'Checked In'),
                                        const SizedBox(width: 20),
                                        _buildLegend(Colors.red, 'Checked Out/Not In'),
                                      ],
                                    ),
                                    const SizedBox(height: 15),
                                  ],
                                ),
                              Text(
                                  'Total Hours Logged for ${psName.isEmpty ? 'Unknown PS' : psName}:',
                                  style: const TextStyle(fontWeight: FontWeight.bold)),
                              const SizedBox(height: 10),
                              psTotalHoursPerMarshal.isEmpty
                                  ? const Text('No records yet to display chart for this PS.')
                                  : SizedBox(
                                      height: 250,
                                      child: BarChart(
                                        BarChartData(
                                          barGroups: _getBarGroups(
                                              psTotalHoursPerMarshal, psMarshalPsNames),
                                          borderData: FlBorderData(
                                            show: true,
                                            border: Border.all(
                                                color: const Color(0xff37434d), width: 1),
                                          ),
                                          gridData: FlGridData(show: false),
                                          titlesData: FlTitlesData(
                                            show: true,
                                            bottomTitles: AxisTitles(
                                              sideTitles: SideTitles(
                                                showTitles: true,
                                                getTitlesWidget: (value, meta) => _getBottomTitles(
                                                    value, meta, psMarshalNames, psMarshalPsNames),
                                                reservedSize: 52,
                                              ),
                                            ),
                                            leftTitles: AxisTitles(
                                              sideTitles: SideTitles(
                                                showTitles: true,
                                                getTitlesWidget: _getLeftTitles,
                                                reservedSize: 52,
                                              ),
                                            ),
                                            topTitles: AxisTitles(
                                                sideTitles: SideTitles(showTitles: false)),
                                            rightTitles: AxisTitles(
                                                sideTitles: SideTitles(showTitles: false)),
                                          ),
                                          alignment: BarChartAlignment.spaceAround,
                                          maxY: psMaxYValue,
                                        ),
                                      ),
                                    ),
                              const SizedBox(height: 15),
                            ],
                          ),
                        ),
                      ),
                    );
                  }),
                  Padding(
                    padding: const EdgeInsets.all(8.0),
                    child: DropdownButton<SortFilter>(
                      value: _selectedFilter,
                      onChanged: (SortFilter? newValue) {
                        if (newValue != null) {
                          setState(() {
                            _selectedFilter = newValue;
                          });
                        }
                      },
                      items: SortFilter.values.map((SortFilter filter) {
                        return DropdownMenuItem<SortFilter>(
                          value: filter,
                          child: Text(filter.toString().split('.').last),
                        );
                      }).toList(),
                    ),
                  ),
                  currentFilteredRecords.isEmpty
                      ? const Center(child: Text('No attendance records found for this filter.'))
                      : ListView.builder(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          itemCount: currentFilteredRecords.length,
                          itemBuilder: (context, index) {
                            final record = currentFilteredRecords[index];
                            return Card(
                              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                              child: Padding(
                                padding: const EdgeInsets.all(16.0),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                      children: [
                                        Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Text('Name: ${record.name}',
                                                style:
                                                    const TextStyle(fontWeight: FontWeight.bold)),
                                            Text('PS Name: ${record.psName}',
                                                style:
                                                    const TextStyle(fontWeight: FontWeight.w500)),
                                          ],
                                        ),
                                        Row(
                                          children: [
                                            IconButton(
                                              icon: const Icon(Icons.edit_location_alt,
                                                  color: Colors.blue),
                                              onPressed: () => _showEditUserLocationDialog(
                                                  record.userId, record.name),
                                              tooltip: 'Edit Work Location',
                                            ),
                                            // New Edit User Details Button
                                            IconButton(
                                              icon: const Icon(Icons.person_outline_sharp,
                                                  color: Colors.indigo),
                                              onPressed: () =>
                                                  _showEditUserDetailsDialog(record.userId),
                                              tooltip: 'Edit User Details',
                                            ),
                                            IconButton(
                                              icon: const Icon(Icons.delete, color: Colors.red),
                                              onPressed: () =>
                                                  _deleteUser(record.userId, record.name),
                                              tooltip: 'Delete User',
                                            ),
                                          ],
                                        ),
                                      ],
                                    ),
                                    Text('Check-in: ${_formatDateTime(record.checkInTime)}'),
                                    Text(
                                        'Check-out: ${record.checkOutTime != null ? _formatDateTime(record.checkOutTime!) : 'Still checked in'}'),
                                    Text(
                                        'Total Time: ${_formatDuration(record.totalTimeCheckedIn)}'),
                                    Text('Check-in Location: ${record.checkInLocation}'),
                                    Text('Check-out Location: ${record.checkOutLocation ?? 'N/A'}'),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                ],
              ),
            ),
    );
  }

  // --- DIALOGS AND OTHER METHODS ---

  void _showCreateUserDialog() {
    showDialog(
      context: context,
      builder: (context) => const CreateUserDialog(),
    ).then((_) {
      _fetchAttendanceData();
    });
    //
  }

  Future<void> _showEditUserLocationDialog(String userId, String userName) async {
    DocumentSnapshot userDoc =
        await FirebaseFirestore.instance.collection('Users').doc(userId).get();
    double? currentLat = (userDoc.data() as Map<String, dynamic>?)?['workLatitude'] as double?;
    double? currentLon = (userDoc.data() as Map<String, dynamic>?)?['workLongitude'] as double?;
    await showDialog(
      context: context,
      builder: (context) => EditUserLocationDialog(
        userId: userId,
        userName: userName,
        currentLatitude: currentLat,
        currentLongitude: currentLon,
      ),
    ).then((_) {
      _fetchAttendanceData();
    });
    //
  }

  Future<void> _showEditUserDetailsDialog(String userId) async {
    DocumentSnapshot userDoc =
        await FirebaseFirestore.instance.collection('Users').doc(userId).get();
    if (!userDoc.exists) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('User not found.')),
      );
      return;
    }

    Map<String, dynamic> userData = userDoc.data() as Map<String, dynamic>;
    String currentName = userData['Name'] as String? ?? '';
    String currentPsName = userData['psName'] as String? ?? '';
    String currentEmail = userData['email'] as String? ?? '';
    bool currentIsAdmin = userData['isAdmin'] as bool? ?? false;

    await showDialog(
      context: context,
      builder: (context) => EditUserDetailsDialog(
        userId: userId,
        currentName: currentName,
        currentPsName: currentPsName,
        currentEmail: currentEmail,
        currentIsAdmin: currentIsAdmin,
      ),
    ).then((_) {
      _fetchAttendanceData(); // Refresh data after potential edit
    });
  }

  Future<void> _deleteUser(String userId, String userName) async {
    final bool confirm = await showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Confirm Deletion'),
          content: Text('Are you sure you want to delete user "$userName"? '
              'This will remove all their attendance records and their user profile.'),
          actions: <Widget>[
            //
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              style: TextButton.styleFrom(foregroundColor: Colors.red), //
              child: const Text('Delete'),
            ),
          ],
        );
      },
    );
    if (confirm) {
      //
      setState(() {
        _isLoading = true;
      });
      try {
        //
        final attendanceDocs = await FirebaseFirestore.instance
            .collection('Users')
            .doc(userId)
            .collection('attendance')
            .get();
        WriteBatch batch = FirebaseFirestore.instance.batch(); //
        for (var doc in attendanceDocs.docs) {
          batch.delete(doc.reference);
          //
        }
        await batch.commit();

        await FirebaseFirestore.instance.collection('Users').doc(userId).delete();
        ScaffoldMessenger.of(context).showSnackBar(
          //
          SnackBar(
            content: Text('User "$userName" and all their attendance data deleted successfully.'),
            duration: const Duration(seconds: 7),
          ),
        );
        _fetchAttendanceData(); //
      } catch (e) {
        setState(() {
          _isLoading = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          //
          SnackBar(content: Text('Error deleting user "$userName": $e')),
        );
      } //
    }
  }

  Future<void> _logout() async {
    try {
      await FirebaseAuth.instance.signOut();
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(
            builder: (context) =>
                LoginPage()), // Replace LoginPage with your actual login page widget
        (route) => false,
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error logging out: $e')),
      );
    }
  }
}

// --- CreateUserDialog ---
class CreateUserDialog extends StatefulWidget {
  const CreateUserDialog({super.key});

  @override
  State<CreateUserDialog> createState() => _CreateUserDialogState();
  //
}

class _CreateUserDialogState extends State<CreateUserDialog> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _nameController = TextEditingController(); //
  final _psNameController = TextEditingController();
  final _workLatitudeController = TextEditingController();
  final _workLongitudeController = TextEditingController();
  bool _isAdmin = false;
  bool _loading = false; //
  String? _error;
  Future<void> _createUser() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      //
      UserCredential cred = await FirebaseAuth.instance.createUserWithEmailAndPassword(
          email: _emailController.text.trim(), password: _passwordController.text.trim());
      double? workLat; //
      double? workLon;
      if (_workLatitudeController.text.isNotEmpty) {
        workLat = double.tryParse(_workLatitudeController.text.trim());
        if (workLat == null) {
          //
          setState(() {
            _error = 'Invalid Work Latitude. Please enter a number.';
            _loading = false;
          });
          return; //
        }
      }
      if (_workLongitudeController.text.isNotEmpty) {
        workLon = double.tryParse(_workLongitudeController.text.trim());
        if (workLon == null) {
          //
          setState(() {
            _error = 'Invalid Work Longitude. Please enter a number.';
            _loading = false;
          });
          return; //
        }
      }

      await FirebaseFirestore.instance.collection('Users').doc(cred.user!.uid).set({
        'Name': _nameController.text.trim(),
        'psName': _psNameController.text.trim(),
        'email': _emailController.text.trim(),
        'isAdmin': _isAdmin,
        'workLatitude': workLat,
        'workLongitude': workLon,
      });
      if (mounted) {
        //
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('User created successfully!')));
        Navigator.pop(context); //
      }
    } on FirebaseAuthException catch (e) {
      setState(() => _error = e.message);
      //
    } catch (e) {
      setState(() => _error = e.toString());
      //
    } finally {
      setState(() => _loading = false);
      //
    }
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _nameController.dispose();
    _psNameController.dispose();
    _workLatitudeController.dispose();
    _workLongitudeController.dispose();
    super.dispose(); //
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Create New User'),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_error != null) Text(_error!, style: const TextStyle(color: Colors.red)), //
              TextFormField(
                controller: _nameController,
                decoration: const InputDecoration(labelText: 'Name'),
                validator: (v) => v == null || v.isEmpty ? 'Enter name' : null,
              ),
              TextFormField(
                //
                controller: _psNameController,
                decoration: const InputDecoration(labelText: 'PS Name (Police Station)'),
                validator: (v) => v == null || v.isEmpty ? 'Enter police station name' : null,
              ),
              TextFormField(
                //
                controller: _emailController,
                decoration: const InputDecoration(labelText: 'Email'),
                validator: (v) => v == null || !v.contains('@') ? 'Enter email' : null, //
              ),
              TextFormField(
                controller: _passwordController,
                decoration: const InputDecoration(labelText: 'Password'),
                obscureText: true,
                validator: (v) => v == null || v.length < 6 ? 'Min 6 chars' : null, //
              ),
              TextFormField(
                controller: _workLatitudeController,
                decoration: const InputDecoration(labelText: 'Work Location Latitude (Optional)'),
                keyboardType: TextInputType.number, //
                validator: (v) {
                  if (v != null && v.isNotEmpty && double.tryParse(v) == null) {
                    return 'Please enter a valid number for latitude.';
                  }
                  return null; //
                },
              ),
              TextFormField(
                controller: _workLongitudeController,
                decoration: const InputDecoration(labelText: 'Work Location Longitude (Optional)'),
                keyboardType: TextInputType.number, //
                validator: (v) {
                  if (v != null && v.isNotEmpty && double.tryParse(v) == null) {
                    return 'Please enter a valid number for longitude.';
                    //
                  }
                  return null;
                  //
                },
              ),
              CheckboxListTile(
                value: _isAdmin,
                onChanged: (v) => setState(() => _isAdmin = v!),
                title: const Text('Is Admin'),
                controlAffinity: ListTileControlAffinity.leading, //
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _loading ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ), //
        ElevatedButton(
          onPressed: _loading
              ? null
              : () {
                  if (_formKey.currentState!.validate()) _createUser();
                },
          child: _loading
              ? const SizedBox(
                  width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Create'),
        ), //
      ],
    );
  }
}

// --- EditUserLocationDialog ---
class EditUserLocationDialog extends StatefulWidget {
  final String userId;
  final String userName;
  final double? currentLatitude;
  final double? currentLongitude; //

  const EditUserLocationDialog({
    super.key,
    required this.userId,
    required this.userName,
    this.currentLatitude,
    this.currentLongitude,
  });
  @override
  State<EditUserLocationDialog> createState() => _EditUserLocationDialogState(); //
}

class _EditUserLocationDialogState extends State<EditUserLocationDialog> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _latitudeController; //
  late TextEditingController _longitudeController;
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _latitudeController = TextEditingController(text: widget.currentLatitude?.toString() ?? ''); //
    _longitudeController = TextEditingController(text: widget.currentLongitude?.toString() ?? '');
  }

  @override
  void dispose() {
    _latitudeController.dispose();
    _longitudeController.dispose();
    super.dispose();
    //
  }

  Future<void> _updateUserLocation() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      //
      _loading = true;
      _error = null;
    });
    try {
      //
      double? newLat = double.tryParse(_latitudeController.text.trim());
      double? newLon = double.tryParse(_longitudeController.text.trim());
      await FirebaseFirestore.instance.collection('Users').doc(widget.userId).update({
        //
        'workLatitude': _latitudeController.text.isEmpty ? null : newLat,
        'workLongitude': _longitudeController.text.isEmpty ? null : newLon,
      });
      if (mounted) {
        //
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Work location updated for ${widget.userName}')),
        );
        Navigator.pop(context); //
      }
    } catch (e) {
      setState(() {
        _error = 'Failed to update location: $e';
      });
      //
    } finally {
      setState(() {
        _loading = false;
      });
      //
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Edit Work Location for ${widget.userName}'),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_error != null) Text(_error!, style: const TextStyle(color: Colors.red)), //
              TextFormField(
                controller: _latitudeController,
                decoration: const InputDecoration(labelText: 'Work Location Latitude'),
                keyboardType: TextInputType.number,
                validator: (v) {
                  if (v != null && v.isNotEmpty && double.tryParse(v) == null) {
                    //
                    return 'Please enter a valid number.';
                  }
                  return null; //
                },
              ),
              TextFormField(
                controller: _longitudeController,
                decoration: const InputDecoration(labelText: 'Work Location Longitude'),
                keyboardType: TextInputType.number, //
                validator: (v) {
                  //
                  if (v != null && v.isNotEmpty && double.tryParse(v) == null) {
                    return 'Please enter a valid number.'; //
                  }
                  return null;
                  //
                },
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _loading ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ), //
        ElevatedButton(
          onPressed: _loading ? null : _updateUserLocation,
          child: _loading
              ? const SizedBox(
                  width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Save'),
        ), //
      ],
    );
  }
}

// --- NEW EditUserDetailsDialog ---
class EditUserDetailsDialog extends StatefulWidget {
  final String userId;
  final String currentName;
  final String currentPsName;
  final String currentEmail; // Display only
  final bool currentIsAdmin;

  const EditUserDetailsDialog({
    super.key,
    required this.userId,
    required this.currentName,
    required this.currentPsName,
    required this.currentEmail,
    required this.currentIsAdmin,
  });

  @override
  State<EditUserDetailsDialog> createState() => _EditUserDetailsDialogState();
}

class _EditUserDetailsDialogState extends State<EditUserDetailsDialog> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _nameController;
  late TextEditingController _psNameController;
  late bool _isAdmin;
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.currentName);
    _psNameController = TextEditingController(text: widget.currentPsName);
    _isAdmin = widget.currentIsAdmin;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _psNameController.dispose();
    super.dispose();
  }

  Future<void> _updateUserDetails() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      await FirebaseFirestore.instance.collection('Users').doc(widget.userId).update({
        'Name': _nameController.text.trim(),
        'psName': _psNameController.text.trim(),
        'isAdmin': _isAdmin,
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('User details updated for ${widget.currentName}')),
        );
        Navigator.pop(context);
      }
    } catch (e) {
      setState(() {
        _error = 'Failed to update user details: $e';
      });
    } finally {
      setState(() {
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Edit User Details'),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_error != null) Text(_error!, style: const TextStyle(color: Colors.red)),
              TextFormField(
                controller: _nameController,
                decoration: const InputDecoration(labelText: 'Name'),
                validator: (v) => v == null || v.isEmpty ? 'Enter name' : null,
              ),
              TextFormField(
                controller: _psNameController,
                decoration: const InputDecoration(labelText: 'PS Name (Police Station)'),
                validator: (v) => v == null || v.isEmpty ? 'Enter police station name' : null,
              ),
              TextFormField(
                controller: TextEditingController(text: widget.currentEmail), // Display-only
                decoration: const InputDecoration(labelText: 'Email (Not editable)'),
                readOnly: true,
              ),
              CheckboxListTile(
                value: _isAdmin,
                onChanged: (v) => setState(() => _isAdmin = v!),
                title: const Text('Is Admin'),
                controlAffinity: ListTileControlAffinity.leading,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _loading ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _loading ? null : _updateUserDetails,
          child: _loading
              ? const SizedBox(
                  width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Save'),
        ),
      ],
    );
  }
}
