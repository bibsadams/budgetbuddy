import 'dart:typed_data';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image/image.dart' as img;
import 'package:intl/intl.dart';

import 'package:budgetbuddy/widgets/app_gradient_background.dart';
import 'package:budgetbuddy/widgets/pressable_neumorphic.dart';
import 'package:budgetbuddy/widgets/two_decimal_input_formatter.dart';
import 'package:budgetbuddy/widgets/money_field_utils.dart';
import '../../services/local_receipt_service.dart';
import '../../services/shared_account_repository.dart';

/// Page for adding/editing a custom tab record.
/// Mirrors the visual design & interaction pattern of SavingsEditPage
/// but uses a simplified field set: Title, Amount, Date/Time, Note, Receipt.
class CustomTabRecordEditPage extends StatefulWidget {
  final String accountId;
  final String tabId;

  /// Existing record map (if editing) otherwise a seed map for new.
  final Map<String, dynamic> record;
  final SharedAccountRepository? repo; // optional repo to persist directly

  const CustomTabRecordEditPage({
    super.key,
    required this.accountId,
    required this.tabId,
    required this.record,
    this.repo,
  });

  @override
  State<CustomTabRecordEditPage> createState() =>
      _CustomTabRecordEditPageState();
}

class _CustomTabRecordEditPageState extends State<CustomTabRecordEditPage> {
  late TextEditingController _titleCtrl;
  late TextEditingController _amountCtrl;
  late TextEditingController _dateCtrl;
  late TextEditingController _noteCtrl;
  final FocusNode _amountFocus = FocusNode();

  // Multi-image parity
  List<Uint8List> _receipts = [];
  List<String> _receiptUids = [];
  String? _receiptUid; // legacy single uid
  bool _loadingExistingReceipt = false;

  final DateFormat _humanFmt = DateFormat('MMM d, y h:mm a');

  @override
  void initState() {
    super.initState();
    _titleCtrl = TextEditingController(
      text: widget.record['Title']?.toString() ?? '',
    );
    final num? existingAmtNum = widget.record['Amount'] is num
        ? widget.record['Amount'] as num
        : null;
    _amountCtrl = TextEditingController(
      text: existingAmtNum != null && existingAmtNum > 0
          ? NumberFormat.decimalPattern().format(existingAmtNum)
          : '',
    );
    final rawDate = widget.record['Date']?.toString() ?? '';
    if (rawDate.trim().isEmpty) {
      final now = DateTime.now();
      _dateCtrl = TextEditingController(text: _fmtDate(now));
    } else {
      _dateCtrl = TextEditingController(text: rawDate);
    }
    _noteCtrl = TextEditingController(
      text: widget.record['Note']?.toString() ?? '',
    );
    // Load existing multi attachments
    _receiptUids = (widget.record['ReceiptUids'] is List)
        ? (widget.record['ReceiptUids'] as List).whereType<String>().toList()
        : <String>[];
    _receiptUid = widget.record['ReceiptUid']?.toString();
    if (_receiptUids.isNotEmpty ||
        (_receiptUid != null && _receiptUid!.isNotEmpty)) {
      _tryLoadLocalReceipt();
    }
  }

  Future<void> _tryLoadLocalReceipt() async {
    setState(() => _loadingExistingReceipt = true);
    try {
      final List<Uint8List> found = [];
      for (final uid
          in (_receiptUids.isNotEmpty
              ? _receiptUids
              : (_receiptUid != null
                    ? <String>[_receiptUid!]
                    : const <String>[]))) {
        try {
          final path = await LocalReceiptService().pathForReceiptUid(
            accountId: widget.accountId,
            collection: 'custom_${widget.tabId}',
            receiptUid: uid,
          );
          final f = File(path);
          if (await f.exists()) {
            found.add(await f.readAsBytes());
          }
        } catch (_) {}
      }
      if (found.isNotEmpty) {
        setState(() {
          _receipts = found;
        });
      }
    } catch (_) {
      // ignore
    } finally {
      if (mounted) setState(() => _loadingExistingReceipt = false);
    }
  }

  String _fmtDate(DateTime dt) =>
      "${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}";

  @override
  void dispose() {
    _titleCtrl.dispose();
    _amountCtrl.dispose();
    _dateCtrl.dispose();
    _noteCtrl.dispose();
    _amountFocus.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final current = DateTime.tryParse(_dateCtrl.text) ?? DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: current,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null) {
      final dt = DateTime(
        picked.year,
        picked.month,
        picked.day,
        current.hour,
        current.minute,
      );
      _dateCtrl.text = _fmtDate(dt);
      setState(() {});
    }
  }

  Future<void> _pickTime() async {
    final current = DateTime.tryParse(_dateCtrl.text) ?? DateTime.now();
    final t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(current),
    );
    if (t != null) {
      final dt = DateTime(
        current.year,
        current.month,
        current.day,
        t.hour,
        t.minute,
      );
      _dateCtrl.text = _fmtDate(dt);
      setState(() {});
    }
  }

  Future<void> _pickDateAndTime() async {
    final current = DateTime.tryParse(_dateCtrl.text) ?? DateTime.now();
    final pickedDate = await showDatePicker(
      context: context,
      initialDate: current,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (pickedDate == null) return;
    final pickedTime = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(current),
    );
    final dt = DateTime(
      pickedDate.year,
      pickedDate.month,
      pickedDate.day,
      pickedTime?.hour ?? current.hour,
      pickedTime?.minute ?? current.minute,
    );
    _dateCtrl.text = _fmtDate(dt);
    setState(() {});
  }

  // Normalize image bytes: fix EXIF orientation and downscale large images.
  Uint8List _normalizeBytes(Uint8List raw) {
    try {
      final decoded = img.decodeImage(raw);
      if (decoded != null) {
        final normalized = img.bakeOrientation(decoded);
        const maxDim = 1600;
        final w = normalized.width, h = normalized.height;
        img.Image finalImg = normalized;
        if (w > maxDim || h > maxDim) {
          final scale = w >= h ? maxDim / w : maxDim / h;
          final newW = (w * scale).round();
          final newH = (h * scale).round();
          finalImg = img.copyResize(normalized, width: newW, height: newH);
        }
        return Uint8List.fromList(img.encodeJpg(finalImg, quality: 85));
      }
    } catch (_) {}
    return raw;
  }

  Future<void> _pickImage(ImageSource source) async {
    final picker = ImagePicker();
    if (source == ImageSource.gallery) {
      // Multi-select from gallery
      final pickedFiles = await picker.pickMultiImage(imageQuality: 85);
      if (pickedFiles.isEmpty) return;
      final List<Uint8List> loaded = [];
      for (final p in pickedFiles) {
        final raw = await p.readAsBytes();
        loaded.add(_normalizeBytes(Uint8List.fromList(raw)));
      }
      setState(() {
        // Append new selections; do NOT clear existing
        _receipts = List.of(_receipts)..addAll(loaded);
      });
      return;
    }

    // Single capture from camera
    final pickedFile = await picker.pickImage(source: source, imageQuality: 85);
    if (pickedFile == null) return;
    final raw = await pickedFile.readAsBytes();
    final bytes = _normalizeBytes(Uint8List.fromList(raw));
    setState(() {
      _receipts = List.of(_receipts)..add(bytes);
    });
  }

  Future<void> _showImageSourceSheet() async {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.photo_library_outlined),
                title: const Text('Pick from Gallery'),
                onTap: () {
                  Navigator.pop(ctx);
                  _pickImage(ImageSource.gallery);
                },
              ),
              ListTile(
                leading: const Icon(Icons.photo_camera_outlined),
                title: const Text('Take a Photo'),
                onTap: () {
                  Navigator.pop(ctx);
                  _pickImage(ImageSource.camera);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _handleSave() async {
    if (_amountFocus.hasFocus) _amountFocus.unfocus();
    final title = _titleCtrl.text.trim();
    final amountVal = parseLooseAmount(_amountCtrl.text);
    _amountCtrl.text = formatTwoDecimalsGrouped(amountVal);
    final dateStr = _dateCtrl.text.trim();
    final note = _noteCtrl.text.trim();
    final missing = <String>[];
    if (title.isEmpty) missing.add('Title');
    if (amountVal <= 0) missing.add('Amount > 0');
    if (dateStr.isEmpty) missing.add('Date');
    if (missing.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Please complete: ${missing.join(' • ')}')),
      );
      return;
    }

    final out = <String, dynamic>{
      'Title': title,
      'Category': title, // mirror for existing list usage
      'Amount': amountVal,
      'Date': dateStr,
      'Note': note,
      'id': widget.record['id'],
    };

    // Persist attachments: prefer multi
    if (_receipts.isNotEmpty) {
      final List<String> uids = [];
      for (int i = 0; i < _receipts.length; i++) {
        final uid = (_receiptUids.length > i && _receiptUids[i].isNotEmpty)
            ? _receiptUids[i]
            : 'r_${DateTime.now().microsecondsSinceEpoch}_$i';
        try {
          await LocalReceiptService().saveReceipt(
            accountId: widget.accountId,
            collection: 'custom_${widget.tabId}',
            docId: uid,
            bytes: _receipts[i],
            receiptUid: uid,
          );
          uids.add(uid);
        } catch (_) {}
      }
      if (uids.isNotEmpty) {
        out['ReceiptUids'] = uids;
        out.remove('ReceiptUid');
        out.remove('ReceiptUrl');
      }
    } else {
      // No current receipts: if the original record had any attachments (single, multi, or URLs), mark for removal
      final hadSingle =
          (widget.record['ReceiptUid'] as String?)?.isNotEmpty == true;
      final hadMulti =
          widget.record['ReceiptUids'] is List &&
          (widget.record['ReceiptUids'] as List).isNotEmpty;
      final hadUrlSingle =
          (widget.record['ReceiptUrl'] as String?)?.isNotEmpty == true;
      final hadUrlMulti =
          widget.record['ReceiptUrls'] is List &&
          (widget.record['ReceiptUrls'] as List).isNotEmpty;
      if (hadSingle || hadMulti || hadUrlSingle || hadUrlMulti) {
        out['ReceiptRemoved'] = true;
      }
    }

    // If repo provided, write immediately (create or update) then pop with updated data including id
    try {
      if (widget.repo != null) {
        // Distinguish create vs update
        if (widget.record['id'] == null) {
          final newId = await widget.repo!.addCustomTabRecord(
            widget.tabId,
            out,
          );
          out['id'] = newId;
          out['_persisted'] = true; // signal host that cloud write already done
        } else {
          await widget.repo!.updateCustomTabRecord(
            widget.tabId,
            widget.record['id'] as String,
            out,
          );
          out['_persisted'] = true;
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to save to cloud: $e')));
      }
    }
    if (mounted) Navigator.pop(context, out);
  }

  void _handleDelete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Delete record?'),
        content: const Text('This will permanently remove the record.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(d).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(d).pop(true),
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (ok == true) {
      // Attempt cloud delete if repo available and id present
      final id = widget.record['id'] as String?;
      if (id != null && widget.repo != null) {
        try {
          await widget.repo!.deleteCustomTabRecord(widget.tabId, id);
        } catch (e) {
          if (!mounted) return;
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('Cloud delete failed: $e')));
        }
      }
      if (!mounted) return;
      Navigator.pop(context, {'_deleted': true, 'id': id});
    }
  }

  @override
  Widget build(BuildContext context) {
    final dtParsed = DateTime.tryParse(_dateCtrl.text);
    final friendlyDate = dtParsed != null
        ? _humanFmt.format(dtParsed)
        : _dateCtrl.text;
    return AppGradientBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        extendBodyBehindAppBar: true,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          surfaceTintColor: Colors.transparent,
          title: Text(
            widget.record['id'] == null ? 'Add Record' : 'Edit Record',
          ),
          actions: [
            if (widget.record['id'] != null)
              IconButton(
                tooltip: 'Delete',
                icon: const Icon(Icons.delete_outline),
                onPressed: _handleDelete,
              ),
            IconButton(
              onPressed: _handleSave,
              tooltip: 'Save',
              icon: const Icon(Icons.save),
            ),
          ],
        ),
        body: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            24,
            MediaQuery.of(context).padding.top + kToolbarHeight + 16,
            24,
            24 + MediaQuery.of(context).viewInsets.bottom,
          ),
          child: PressableNeumorphic(
            borderRadius: 16,
            padding: const EdgeInsets.all(16),
            useSurfaceBase: true,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: _titleCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Title',
                    prefixIcon: Icon(Icons.label_outline),
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 20),
                TextField(
                  controller: _amountCtrl,
                  focusNode: _amountFocus,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  inputFormatters: [TwoDecimalInputFormatter()],
                  decoration: const InputDecoration(
                    labelText: 'Amount',
                    prefixText: '₱ ',
                    border: OutlineInputBorder(),
                  ),
                  onEditingComplete: () => _amountFocus.unfocus(),
                  onTapOutside: (_) {
                    if (_amountFocus.hasFocus) _amountFocus.unfocus();
                  },
                ),
                Builder(
                  builder: (_) {
                    final amt = parseLooseAmount(_amountCtrl.text);
                    if (amt <= 0) {
                      return const Padding(
                        padding: EdgeInsets.only(top: 8.0),
                        child: Text(
                          'Amount must be greater than 0',
                          style: TextStyle(color: Colors.red),
                        ),
                      );
                    }
                    return const SizedBox.shrink();
                  },
                ),
                const SizedBox(height: 20),
                TextField(
                  controller: _dateCtrl,
                  readOnly: true,
                  onTap: _pickDateAndTime,
                  decoration: InputDecoration(
                    labelText: 'Date & time',
                    prefixIcon: const Icon(Icons.event_outlined),
                    border: const OutlineInputBorder(),
                    suffixIconConstraints: const BoxConstraints(minWidth: 96),
                    suffixIcon: SizedBox(
                      width: 96,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          IconButton(
                            onPressed: _pickDate,
                            icon: const Icon(Icons.calendar_today_outlined),
                          ),
                          IconButton(
                            onPressed: _pickTime,
                            icon: const Icon(Icons.access_time),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    friendlyDate,
                    style: const TextStyle(color: Colors.grey),
                  ),
                ),
                const SizedBox(height: 20),
                TextField(
                  controller: _noteCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Note',
                    prefixIcon: Icon(Icons.notes_outlined),
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 24),
                if (_loadingExistingReceipt)
                  const Center(
                    child: Padding(
                      padding: EdgeInsets.all(12),
                      child: CircularProgressIndicator(),
                    ),
                  )
                else ...[
                  if (_receipts.isNotEmpty)
                    Stack(
                      alignment: Alignment.topRight,
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: Image.memory(
                            _receipts.first,
                            width: MediaQuery.of(context).size.width * 0.9,
                            height: MediaQuery.of(context).size.height * 0.4,
                            fit: BoxFit.cover,
                          ),
                        ),
                        if (_receipts.length > 1)
                          Container(
                            margin: const EdgeInsets.all(8),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.black87,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(
                              '+${_receipts.length - 1}',
                              style: const TextStyle(color: Colors.white),
                            ),
                          ),
                      ],
                    ),
                ],
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    ElevatedButton.icon(
                      onPressed: _showImageSourceSheet,
                      icon: const Icon(Icons.attachment_outlined),
                      label: const Text('Attach Image'),
                    ),
                    if (_receipts.isNotEmpty)
                      OutlinedButton.icon(
                        onPressed: () => setState(() {
                          _receipts.clear();
                          _receiptUids.clear();
                          _receiptUid = null;
                        }),
                        icon: const Icon(Icons.delete_outline),
                        label: const Text('Remove all'),
                      ),
                    // Removed 'View Receipts' button from edit page; viewing is in details page only
                  ],
                ),
              ],
            ),
          ),
        ),
        bottomNavigationBar: Padding(
          padding: const EdgeInsets.all(16),
          child: PressableNeumorphic(
            borderRadius: 16,
            useSurfaceBase: true,
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                minimumSize: const Size.fromHeight(56),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
              onPressed: _handleSave,
              icon: const Icon(Icons.save),
              label: Text(
                widget.record['id'] == null ? 'Save Record' : 'Update Record',
              ),
            ),
          ),
        ),
      ),
    );
  }
}
