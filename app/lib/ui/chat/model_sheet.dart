// Portions derived from PiPilot (https://github.com/CikeSeven/pi_pilot), MIT, Copyright (c) 2026 CikeSeven. See THIRD_PARTY_NOTICES.md.
// Local changes: a glass bottom sheet fed by `session/modelCatalog`, with a
// channel filter, model cards and a capsule effort selector.

import 'dart:async';
import 'dart:math' as math;

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/models_state.dart';
import '../../state/settings_state.dart';
import '../common/app_sheet.dart';
import '../common/empty_view.dart';
import '../common/pressable.dart';
import '../common/segmented_pill.dart';
import '../common/sheet_title_bar.dart';
import '../common/smooth_size.dart';
import '../common/read_list_status.dart';
import '../common/ui_trace.dart';
import '../onboarding/api_key_page.dart';
import '../providers/provider_form_page.dart';
import '../providers/providers_page.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';

/// 模型名的短写:去掉 "DeepSeek-" 前缀,连字符换空格,首字母大写。
/// `DeepSeek-V4-Pro` → `V4 Pro`。
String shortModelName(String raw) {
  final stripped = raw.replaceFirst(RegExp(r'^deepseek[-_ ]?', caseSensitive: false), '');
  final words = stripped
      .split(RegExp(r'[-_ ]+'))
      .where((w) => w.isNotEmpty)
      .map((w) => w.length == 1 ? w.toUpperCase() : w[0].toUpperCase() + w.substring(1))
      .join(' ');
  return words.isEmpty ? raw : words;
}

/// 胶囊上的模型短名;没有选择时是「选择模型」。
String modelShortName(ModelSelection? selection, ModelCatalog? catalog) {
  if (selection == null) return appL10n.viewModelSelect;
  return shortModelName(findModel(catalog, selection)?.name ?? selection.model);
}

/// 思考深度的中文名。协议词(off/low/high/max)不直接给人看。
String effortLabel(String id, [String? fallback]) => switch (id) {
  'off' || 'none' => appL10n.viewModelThinkingOff,
  'minimal' => appL10n.viewModelThinkingMinimal,
  'low' => appL10n.viewModelThinkingLow,
  'medium' => appL10n.viewModelThinkingMedium,
  'high' => appL10n.viewModelThinkingHigh,
  'xhigh' => appL10n.viewModelThinkingXhigh,
  'max' => appL10n.viewModelThinkingMax,
  _ => fallback ?? id,
};

/// The model in a phone's open composer: a plain pill beside the +, the same weight as
/// it, saying what this message goes out with and a tap from changing it.
class ComposerModelPill extends ConsumerWidget {
  const ComposerModelPill({super.key, required this.selection, required this.onSelected});

  final ModelSelection? selection;
  final ValueChanged<ModelSelection> onSelected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final catalog = ref.watch(currentModelCatalogProvider);
    final effective = selection ?? catalog?.defaultSelection;
    final effort = effective?.reasoningEffort;
    final name = modelShortName(effective, catalog);
    void open() => showModelSheet(context, current: effective, onSelected: onSelected);
    return Semantics(
      button: true,
      label: [
        l10n.viewModelLabel(name),
        if (effort != null) l10n.viewModelEffortLabel(effortLabel(effort)),
      ].join(l10n.viewListSeparator),
      excludeSemantics: true,
      onTap: open,
      child: InkResponse(
        key: const ValueKey('composer-model'),
        onTap: open,
        highlightShape: BoxShape.rectangle,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          constraints: const BoxConstraints(minHeight: 36),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: ShapeDecoration(color: colors.onSurface.withValues(alpha: 0.06), shape: const StadiumBorder()),
          // As wide as its words: the row's free space stays between it and the keys.
          child: Center(
            widthFactor: 1,
            heightFactor: 1,
            child: Text(
              effort == null ? name : '$name ${effortLabel(effort)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelMedium?.copyWith(
                fontSize: 12.5,
                color: colors.onSurface,
                fontWeight: FontWeight.w400,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 顶栏右侧的模型胶囊:"✦ V4 Pro · 高 ⌄"。换模型时宽度平滑过渡、文字淡变。
///
/// 位置不够时依次让出:先收起「· 高」(读屏照读),再截短模型名,最后只留
/// ✦ 和 ⌄。给多宽由顶栏量了再定([ChatHeader]),胶囊自己不猜屏宽:它的
/// 最小固有宽度是「完整模型名、不带深度」,最大固有宽度是「名字加深度」。
class ModelChip extends ConsumerWidget {
  const ModelChip({super.key, required this.selection, required this.onSelected, this.grouped = false});

  /// 当前生效的选择;null 时显示目录默认值。
  final ModelSelection? selection;
  final ValueChanged<ModelSelection> onSelected;
  final bool grouped;

  // The chevron's glyph carries ~4 of its own air on the right: 12 + 0 on
  // the left reads the same as 8 + 4 on the right.
  static const _padStart = 12.0;
  static const _padEnd = 8.0;
  static const _chevron = 16.0;

  /// The narrowest the chip gets: the chevron, no words.
  static const compactWidth = _padStart + _chevron + _padEnd;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final catalog = ref.watch(currentModelCatalogProvider);
    final effective = selection ?? catalog?.defaultSelection;
    final effort = effective?.reasoningEffort;
    final label = modelShortName(effective, catalog);
    final quick = AppMotion.of(context, AppMotion.quick);
    final em = MediaQuery.textScalerOf(context).scale(13);
    final style = theme.textTheme.labelMedium?.copyWith(fontSize: 13);
    void open() => showModelSheet(context, current: effective, onSelected: onSelected);
    return GlassSurface(
      tier: GlassTier.chrome,
      stadium: true,
      grouped: grouped,
      onTap: open,
      child: Semantics(
        label: [
          l10n.viewModelLabel(label),
          if (effort != null) l10n.viewModelEffortLabel(effortLabel(effort)),
        ].join(l10n.viewListSeparator),
        button: true,
        onTap: open,
        excludeSemantics: true,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(_padStart, 0, _padEnd, 0),
            child: SmoothSize(
              duration: AppMotion.of(context, AppMotion.standard),
              curve: AppMotion.std,
              alignment: Alignment.centerRight,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: AnimatedSwitcher(
                      duration: quick,
                      layoutBuilder: (current, previous) =>
                          Stack(alignment: Alignment.centerLeft, children: [...previous, ?current]),
                      child: _ChipLabel(
                        key: ValueKey('$label\u0000$effort'),
                        gap: 5,
                        // About two letters and an ellipsis; a long name
                        // stops at ten characters' width.
                        minTextWidth: em * 2.5,
                        maxTextWidth: em * 10,
                        children: [
                          if (effort != null)
                            Text.rich(
                              TextSpan(
                                children: [
                                  TextSpan(text: label),
                                  TextSpan(
                                    text: ' · ${effortLabel(effort)}',
                                    style: TextStyle(
                                      color: theme.colorScheme.onSurfaceVariant,
                                      fontWeight: FontWeight.w400,
                                    ),
                                  ),
                                ],
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: style,
                            ),
                          Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: style),
                        ],
                      ),
                    ),
                  ),
                  Icon(AppIcons.expand, size: _chevron, color: theme.colorScheme.onSurfaceVariant),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The chip's words: the first of [children] that fits whole (the name with
/// its depth, then the name alone). The last one shortens with an ellipsis
/// when nothing fits, and the words go altogether, with the [gap] in front of
/// them, once less than [minTextWidth] would show. Never wider than
/// [maxTextWidth].
///
/// Its min intrinsic width is the last child whole, its max intrinsic width
/// the first: what the header weighs the title against.
class _ChipLabel extends MultiChildRenderObjectWidget {
  const _ChipLabel({
    super.key,
    required this.gap,
    required this.minTextWidth,
    required this.maxTextWidth,
    required super.children,
  });

  final double gap;
  final double minTextWidth;
  final double maxTextWidth;

  @override
  MultiChildRenderObjectElement createElement() => _ChipLabelElement(this);

  @override
  _RenderChipLabel createRenderObject(BuildContext context) => _RenderChipLabel(gap, minTextWidth, maxTextWidth);

  @override
  void updateRenderObject(BuildContext context, _RenderChipLabel renderObject) {
    renderObject
      ..gap = gap
      ..minTextWidth = minTextWidth
      ..maxTextWidth = maxTextWidth;
  }
}

/// Only the shown words are on stage (finders, like [IndexedStack]'s).
class _ChipLabelElement extends MultiChildRenderObjectElement {
  _ChipLabelElement(super.widget);

  @override
  void debugVisitOnstageChildren(ElementVisitor visitor) {
    final shown = (renderObject as _RenderChipLabel).shown;
    for (final child in children) {
      if (shown != null && identical(child.renderObject, shown)) visitor(child);
    }
  }
}

class _ChipLabelParentData extends ContainerBoxParentData<RenderBox> {}

class _RenderChipLabel extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _ChipLabelParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _ChipLabelParentData> {
  _RenderChipLabel(this._gap, this._minTextWidth, this._maxTextWidth);

  /// Rounding between the header's arithmetic and the text's own width.
  static const _slack = 0.5;

  double _gap;
  set gap(double value) {
    if (value == _gap) return;
    _gap = value;
    markNeedsLayout();
  }

  double _minTextWidth;
  set minTextWidth(double value) {
    if (value == _minTextWidth) return;
    _minTextWidth = value;
    markNeedsLayout();
  }

  double _maxTextWidth;
  set maxTextWidth(double value) {
    if (value == _maxTextWidth) return;
    _maxTextWidth = value;
    markNeedsLayout();
  }

  /// The child on screen after the last layout; null when the words are gone.
  RenderBox? shown;

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _ChipLabelParentData) {
      child.parentData = _ChipLabelParentData();
    }
  }

  double _whole(RenderBox child) => math.min(child.getMaxIntrinsicWidth(double.infinity), _maxTextWidth);

  /// Which child [maxWidth] shows, and how wide its text may run.
  (RenderBox, double)? _pick(double maxWidth) {
    final room = math.min(maxWidth - _gap, _maxTextWidth);
    if (room < _minTextWidth) return null;
    for (var child = firstChild; child != null; child = childAfter(child)) {
      final whole = _whole(child);
      if (whole <= room + _slack) return (child, whole);
      if (child == lastChild) return (child, room);
    }
    return null;
  }

  @override
  double computeMinIntrinsicWidth(double height) => lastChild == null ? 0 : _gap + _whole(lastChild!);

  @override
  double computeMaxIntrinsicWidth(double height) => firstChild == null ? 0 : _gap + _whole(firstChild!);

  @override
  double computeMinIntrinsicHeight(double width) => lastChild?.getMinIntrinsicHeight(double.infinity) ?? 0;

  @override
  double computeMaxIntrinsicHeight(double width) => lastChild?.getMaxIntrinsicHeight(double.infinity) ?? 0;

  @override
  Size computeDryLayout(covariant BoxConstraints constraints) {
    final pick = _pick(constraints.maxWidth);
    if (pick == null) return constraints.smallest;
    final (child, width) = pick;
    final text = child.getDryLayout(BoxConstraints(maxWidth: width));
    return constraints.constrain(Size(_gap + text.width, text.height));
  }

  @override
  void performLayout() {
    final pick = _pick(constraints.maxWidth);
    shown = pick?.$1;
    if (pick == null) {
      size = constraints.smallest;
      return;
    }
    final (child, width) = pick;
    child.layout(BoxConstraints(maxWidth: width), parentUsesSize: true);
    (child.parentData! as _ChipLabelParentData).offset = Offset(_gap, 0);
    size = constraints.constrain(Size(_gap + child.size.width, child.size.height));
  }

  @override
  double? computeDistanceToActualBaseline(TextBaseline baseline) => shown?.getDistanceToActualBaseline(baseline);

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = shown;
    if (child == null) return;
    final childOffset = (child.parentData! as _ChipLabelParentData).offset + offset;
    context.paintChild(child, childOffset);
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    final child = shown;
    if (child == null) return false;
    final offset = (child.parentData! as _ChipLabelParentData).offset;
    return result.addWithPaintOffset(
      offset: offset,
      position: position,
      hitTest: (result, transformed) => child.hitTest(result, position: transformed),
    );
  }

  @override
  void visitChildrenForSemantics(RenderObjectVisitor visitor) {
    if (shown case final child?) visitor(child);
  }
}

/// 模型弹层:点模型卡立即生效(深度沿用或取默认);选思考深度立即生效,
/// 滑块落位后弹层自己收起。
Future<void> showModelSheet(
  BuildContext context, {
  required ModelSelection? current,
  required ValueChanged<ModelSelection> onSelected,
  bool confirmSelection = false,
}) {
  return showAppSheet<void>(
    context,
    isScrollControlled: true,
    builder: (context) => _ModelSheet(current: current, onSelected: onSelected, confirmSelection: confirmSelection),
  );
}

/// ```
///                       ───
///   ╭────────────────────────────╮  (( DeepSeek ▾ ))
///   │ 搜索模型                    │
///   ╰────────────────────────────╯
///
///   ╭─────────────────╮  ╭─────────────────╮
///   │ V4 Pro       (✓)│  │ V41 Flash    ( )│
///   │ 更强的推理与编码  │  │ 更快、更省        │
///   ╰─────────────────╯  ╰─────────────────╯
///
///   思考深度
///   (( 不思考 )  低      ( 高 )     最高   )
/// ```
///
/// 渠道是一个下拉按钮:展开后列出全部渠道,选中只筛选、不改当前选择;打开时
/// 停在当前模型所在的渠道。单渠道时连这个按钮都不出现。确认模式(设置页用)
/// 换了模型不立即回调,由底部保存栏提交。
class _ModelSheet extends ConsumerStatefulWidget {
  const _ModelSheet({required this.current, required this.onSelected, required this.confirmSelection});

  final ModelSelection? current;
  final ValueChanged<ModelSelection> onSelected;
  final bool confirmSelection;

  @override
  ConsumerState<_ModelSheet> createState() => _ModelSheetState();
}

class _ModelSheetState extends ConsumerState<_ModelSheet> {
  late ModelSelection? _selection = widget.current;
  late final Object _scope = ref.read(modelSelectionScopeProvider);

  bool get _active => identical(_scope, ref.read(modelSelectionScopeProvider));

  /// The channel being browsed; null follows the selected model's.
  String? _channel;

  /// Whether the channel dropdown is expanded.
  bool _channelExpanded = false;
  final _channelButtonKey = GlobalKey();
  final _channelOverlay = OverlayPortalController();

  /// Search query for filtering models.
  String _searchQuery = '';
  late final TextEditingController _searchController = TextEditingController();

  /// Closes the sheet once the effort thumb has landed.
  Timer? _close;

  @override
  void dispose() {
    _close?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  void _toggleChannels() {
    setState(() => _channelExpanded = !_channelExpanded);
    if (_channelExpanded) {
      _channelOverlay.show();
    } else {
      _channelOverlay.hide();
    }
  }

  void _clearSearch() {
    _searchController.clear();
    setState(() => _searchQuery = '');
  }

  void _pickModel(ModelInfo model) {
    final view = ref.read(modelListViewProvider);
    if (!_active || view.readOnly) return;
    final available = findModel(view.value, ModelSelection(provider: model.provider, model: model.id));
    if (available == null || !identical(available, model)) return;
    final keep = _selection?.reasoningEffort;
    final supported = model.efforts.any((e) => e.id == keep);
    final next = ModelSelection(
      provider: model.provider,
      model: model.id,
      reasoningEffort: supported ? keep : startingEffort(model),
    );
    setState(() {
      _selection = next;
      _channel = model.provider;
    });
    if (!widget.confirmSelection) widget.onSelected(next);
  }

  void _pickEffort(String effort) {
    final view = ref.read(modelListViewProvider);
    if (!_active || view.readOnly) return;
    final current = _selection;
    if (current == null) return;
    final available = findModel(view.value, current);
    if (available == null || !available.efforts.any((entry) => entry.id == effort)) return;
    final next = ModelSelection(provider: current.provider, model: current.model, reasoningEffort: effort);
    setState(() => _selection = next);
    if (widget.confirmSelection) return;
    widget.onSelected(next);
    _close?.cancel();
    final settle = AppMotion.reduced(context) ? Duration.zero : AppMotion.standard + const Duration(milliseconds: 120);
    _close = Timer(settle, () {
      if (mounted) Navigator.of(context).maybePop();
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final catalogAsync = ref.watch(modelCatalogProvider);
    final view = ref.watch(modelListViewProvider);
    final catalog = view.value;
    final active = identical(_scope, ref.watch(modelSelectionScopeProvider));

    final Widget body;
    var picking = false;
    if (catalog == null) {
      body = catalogAsync.isLoading
          ? const _Loading()
          : catalogAsync.hasError
          ? EmptyView(
              padding: _emptyPadding,
              icon: AppIcons.offline,
              title: l10n.viewModelLoadFailed,
              action: FilledButton.tonal(
                onPressed: () => ref.invalidate(modelCatalogProvider),
                child: Text(l10n.commonRetry),
              ),
            )
          : EmptyView(
              padding: _emptyPadding,
              icon: AppIcons.disconnected,
              title: l10n.viewModelDisconnected,
              message: l10n.viewModelConnectHint,
            );
    } else {
      final groups = [
        for (final group in catalog.groups)
          if (group.models.isNotEmpty) group,
      ];
      if (groups.isEmpty) {
        body = _EmptyCatalog(
          // A failing provider counts: something is set up, just not working.
          configured: ref.watch(settingsProvider.select((s) => s.hasModelAccess)) || catalog.failures.isNotEmpty,
          failure: catalog.failures.isEmpty ? null : catalog.failures.first.message,
        );
      } else {
        picking = true;
        body = _picker(groups, findModel(catalog, _selection), readOnly: view.readOnly || !active);
      }
    }

    final sheet = AnimatedPadding(
      // 搜索框唤起输入法时,弹层随其抬起——与主页 composer 同一套动效。
      duration: AppMotion.of(context, AppMotion.quick),
      curve: AppMotion.std,
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
        padding: const EdgeInsets.only(bottom: 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!picking)
              SheetTitleBar(catalog == null ? l10n.viewModelSelect : readListHeading(l10n.viewModelSelect, view.status)),
            body,
            if (picking && widget.confirmSelection && !isValidModelSelection(catalog, _selection))
              Padding(
                padding: const EdgeInsets.fromLTRB(SheetTitleBar.inset, 16, SheetTitleBar.inset, 0),
                child: Text(l10n.engineNewChatDefaultsSelectionUnavailable),
              ),
            if (picking && widget.confirmSelection)
              Padding(
                padding: const EdgeInsets.fromLTRB(SheetTitleBar.inset, 20, SheetTitleBar.inset, 0),
                child: FilledButton(
                  onPressed: !active || view.readOnly || !isValidModelSelection(catalog, _selection)
                      ? null
                      : () {
                          final currentView = ref.read(modelListViewProvider);
                          if (!_active ||
                              currentView.readOnly ||
                              !isValidModelSelection(currentView.value, _selection)) {
                            return;
                          }
                          widget.onSelected(_selection!);
                          Navigator.of(context).pop();
                        },
                  child: Text(l10n.commonSave),
                ),
              ),
            // 「管理模型 ›」: 设置 › 模型, over the sheet (back returns here).
            if (picking) ...[const SizedBox(height: 12), const ManageModelsLink()],
          ],
        ),
      ),
    ),
    );
    return UiTrace(scope: 'models', child: sheet);
  }

  Widget _picker(List<ProviderGroup> groups, ModelInfo? selected, {required bool readOnly}) {
    final shownId = _channel ?? selected?.provider;
    final shown = groups.firstWhere((g) => g.id == shownId, orElse: () => groups.first);
    final efforts = selected?.efforts ?? const <ReasoningEffort>[];
    const inset = SheetTitleBar.inset;

    // 搜索过滤:当前渠道下匹配名字或描述。
    final query = _searchQuery.trim().toLowerCase();
    final filtered = query.isEmpty
        ? shown.models
        : shown.models.where((m) {
            final name = shortModelName(m.name).toLowerCase();
            final desc = (m.description ?? '').toLowerCase();
            return name.contains(query) || desc.contains(query);
          }).toList();

    return Padding(
      padding: const EdgeInsets.fromLTRB(inset, 8, inset, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          // 搜索框 + 渠道按钮,同一行
          Row(
            children: [
              Expanded(
                child: _SearchField(
                  controller: _searchController,
                  query: _searchQuery,
                  onChanged: (v) => setState(() => _searchQuery = v),
                  onClear: _clearSearch,
                ),
              ),
              if (groups.length > 1) ...[
                const SizedBox(width: 8),
                OverlayPortal(
                  overlayLocation: OverlayChildLocation.rootOverlay,
                  controller: _channelOverlay,
                  overlayChildBuilder: (overlayContext) {
                    final button = _channelButtonKey.currentContext?.findRenderObject();
                    if (button is! RenderBox || !button.attached) return const SizedBox.shrink();
                    return CustomSingleChildLayout(
                      delegate: _ChannelDropdownLayout(
                        anchor: button.localToGlobal(Offset.zero) & button.size,
                        safeArea: MediaQuery.paddingOf(overlayContext),
                      ),
                      child: _ChannelDropdownList(
                        groups: groups,
                        shown: shown.id,
                        onSelected: (id) {
                          setState(() {
                            _channel = id;
                            _channelExpanded = false;
                          });
                          _channelOverlay.hide();
                        },
                      ),
                    );
                  },
                  child: SizedBox(
                    key: _channelButtonKey,
                    child: _ChannelPillButton(label: shown.name, expanded: _channelExpanded, onTap: _toggleChannels),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 10),
          // 模型列表 + 下拉浮层
          Stack(
            clipBehavior: Clip.none,
            children: [
              if (filtered.isEmpty)
                const _EmptySearch()
              else
                _modelGrid(filtered, selected, readOnly, ValueKey('${shown.id}:$query')),

            ],
          ),
          _effortSelector(efforts, selected, readOnly),
        ],
      ),
    );
  }

  Widget _modelGrid(List<ModelInfo> models, ModelInfo? selected, bool readOnly, Key key) {
    final quick = AppMotion.of(context, AppMotion.quick);
    return SmoothSize(
      duration: AppMotion.of(context, AppMotion.standard),
      curve: AppMotion.std,
      alignment: Alignment.topCenter,
      child: AnimatedSwitcher(
        duration: quick,
        switchInCurve: AppMotion.enter,
        switchOutCurve: AppMotion.exit,
        layoutBuilder: (current, previous) =>
            Stack(alignment: Alignment.topCenter, children: [...previous, ?current]),
        child: _ModelGrid(
          key: key,
          models: models,
          selected: selected,
          onPick: readOnly ? null : _pickModel,
        ),
      ),
    );
  }

  Widget _effortSelector(List<ReasoningEffort> efforts, ModelInfo? selected, bool readOnly) {
    final quick = AppMotion.of(context, AppMotion.quick);
    // Fades out first, then the height folds away (and the reverse on the
    // way in), so nothing below jumps.
    return SmoothSize(
      duration: AppMotion.of(context, AppMotion.collapse),
      curve: AppMotion.collapseCurve,
      alignment: Alignment.topCenter,
      child: AnimatedSwitcher(
        duration: quick,
        layoutBuilder: (current, previous) =>
            Stack(alignment: Alignment.topCenter, children: [...previous, ?current]),
        child: efforts.length < 2
            ? const SizedBox(key: ValueKey('none'), width: double.infinity)
            : Column(
                key: const ValueKey('effort'),
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(height: 16),
                  // The picker already insets its column, so the label sits 8
                  // inside it -- not another whole inset in from it.
                  SheetSectionLabel(appL10n.viewModelEffort, inset: 0),
                  // The picker already insets its column: the pill spans it,
                  // level with the cards, the search field and its own label.
                  SegmentedPill<String>(
                    height: 40,
                    segments: [for (final e in efforts) PillSegment(e.id, effortLabel(e.id, e.name))],
                    selected: _selection?.reasoningEffort ?? selected?.defaultEffort ?? efforts.first.id,
                    onChanged: readOnly
                        ? null
                        : (effort) {
                            if (identical(
                              findModel(ref.read(modelListViewProvider).value, _selection),
                              selected,
                            )) {
                              _pickEffort(effort);
                            }
                          },
                  ),
                ],
              ),
      ),
    );
  }
}

/// 选择模型底部的「管理模型 ›」:居中的文字键,去 设置 › 模型。
class ManageModelsLink extends StatelessWidget {
  const ManageModelsLink({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Center(
      child: TextButton(
        onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const ProvidersPage())),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(l10n.nearbyManageModels),
            const SizedBox(width: 2),
            const Icon(AppIcons.disclosure, size: 14),
          ],
        ),
      ),
    );
  }
}

/// 渠道选择胶囊按钮:右对齐的一颗胶囊,显示当前渠道名 + 箭头。
class _ChannelPillButton extends StatelessWidget {
  const _ChannelPillButton({required this.label, required this.expanded, required this.onTap});

  final String label;
  final bool expanded;
  final VoidCallback onTap;

  static const maxWidth = 150.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final quick = AppMotion.of(context, AppMotion.quick);
    return Semantics(
      button: true,
      label: label,
      onTap: onTap,
      excludeSemantics: true,
      child: Pressable(
        onTap: onTap,
        child: SizedBox(
          height: 36,
          child: AnimatedContainer(
            duration: quick,
            curve: AppMotion.std,
            padding: const EdgeInsets.only(left: 10, right: 8),
            decoration: ShapeDecoration(
              color: dark ? Colors.white.withValues(alpha: 0.08) : colors.onSurface.withValues(alpha: 0.06),
              shape: const StadiumBorder(),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(AppIcons.model, size: 14, color: colors.primary),
                const SizedBox(width: 6),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: maxWidth - 14 - 6 - 8 - 12 - 8),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    physics: const AlwaysScrollableScrollPhysics(),
                    child: Text(
                      label,
                      maxLines: 1,
                      softWrap: false,
                      style: theme.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                AnimatedRotation(
                  turns: expanded ? 0.5 : 0,
                  duration: quick,
                  curve: AppMotion.std,
                  child: Icon(AppIcons.expand, size: 12, color: colors.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ChannelDropdownLayout extends SingleChildLayoutDelegate {
  const _ChannelDropdownLayout({required this.anchor, required this.safeArea});

  final Rect anchor;
  final EdgeInsets safeArea;

  static const _gap = 8.0;
  static const _margin = 8.0;
  static const _maxWidth = 320.0;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final room = math.max(0.0, anchor.left - _gap - safeArea.left - _margin);
    final width = math.min(_maxWidth, room);
    return BoxConstraints(
      minWidth: width,
      maxWidth: width,
      maxHeight: math.max(0.0, constraints.maxHeight - safeArea.vertical - _margin * 2),
    );
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final minY = safeArea.top + _margin;
    final maxY = math.max(minY, size.height - safeArea.bottom - _margin - childSize.height);
    final centeredY = anchor.center.dy - childSize.height / 2;
    final y = math.max(minY, math.min(maxY, centeredY));
    return Offset(math.max(safeArea.left + _margin, anchor.left - _gap - childSize.width), y);
  }

  @override
  bool shouldRelayout(_ChannelDropdownLayout oldDelegate) =>
      anchor != oldDelegate.anchor || safeArea != oldDelegate.safeArea;
}

/// 展开的渠道下拉列表:浮在模型卡上方,圆角矩形,带阴影。
class _ChannelDropdownList extends StatelessWidget {
  const _ChannelDropdownList({required this.groups, required this.shown, required this.onSelected});

  final List<ProviderGroup> groups;
  final String shown;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    return Container(
      decoration: ShapeDecoration(
        color: dark ? const Color(0xFF1C1C1E) : Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppShape.lg)),
        shadows: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.12),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppShape.lg),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
            for (var i = 0; i < groups.length; i++) ...[
              if (i > 0)
                Divider(
                  height: 1,
                  thickness: 1,
                  color: dark ? Colors.white.withValues(alpha: 0.08) : colors.onSurface.withValues(alpha: 0.06),
                ),
              _ChannelDropdownItem(
                label: groups[i].name,
                selected: groups[i].id == shown,
                onTap: () => onSelected(groups[i].id),
              ),
            ],
          ],
        ),
      ),
    ),
  );
}
}

/// 下拉列表里的单个渠道项。
class _ChannelDropdownItem extends StatelessWidget {
  const _ChannelDropdownItem({required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final quick = AppMotion.of(context, AppMotion.quick);
    return Semantics(
      button: true,
      selected: selected,
      inMutuallyExclusiveGroup: true,
      label: label,
      onTap: onTap,
      excludeSemantics: true,
      child: Pressable(
        onTap: onTap,
        child: AnimatedContainer(
          duration: quick,
          curve: AppMotion.std,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          color: selected ? colors.primary.withValues(alpha: 0.1) : Colors.transparent,
          child: Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  ),
                ),
              ),
              if (selected)
                Icon(AppIcons.selected, size: 16, color: colors.primary),
            ],
          ),
        ),
      ),
    );
  }
}

/// 搜索框:胶囊形状,左侧搜索图标,右侧清空按钮。
class _SearchField extends StatelessWidget {
  const _SearchField({required this.controller, required this.query, required this.onChanged, required this.onClear});

  final TextEditingController controller;
  final String query;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    return SizedBox(
      height: 36,
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        style: theme.textTheme.bodyMedium,
        textAlignVertical: TextAlignVertical.center,
        decoration: InputDecoration(
          isCollapsed: true,
          contentPadding: EdgeInsets.zero,
          filled: true,
          fillColor: dark ? Colors.white.withValues(alpha: 0.07) : colors.onSurface.withValues(alpha: 0.06),
          border: const OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(AppShape.lg)),
            borderSide: BorderSide.none,
          ),
          prefixIcon: Icon(AppIcons.search, size: 16, color: colors.onSurfaceVariant),
          suffixIcon: query.isEmpty
              ? null
              : GestureDetector(
                  onTap: onClear,
                  child: Icon(AppIcons.close, size: 16, color: colors.onSurfaceVariant),
                ),
          hintText: appL10n.engineProviderSearchModels,
          hintStyle: theme.textTheme.bodyMedium?.copyWith(color: colors.onSurfaceVariant),
        ),
      ),
    );
  }
}

/// 搜索无结果时的空状态。
class _EmptySearch extends StatelessWidget {
  const _EmptySearch();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(AppIcons.search, size: 24, color: colors.onSurfaceVariant),
          const SizedBox(height: 8),
          Text(
            appL10n.engineProviderNoMatchingModels,
            style: theme.textTheme.bodyMedium?.copyWith(color: colors.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

/// 两列等宽的模型卡,同一行等高、间距 12;单数时最后一张占满整行。
class _ModelGrid extends StatelessWidget {
  const _ModelGrid({super.key, required this.models, required this.selected, required this.onPick});

  final List<ModelInfo> models;
  final ModelInfo? selected;
  final ValueChanged<ModelInfo>? onPick;

  static const gap = 12.0;

  @override
  Widget build(BuildContext context) {
    Widget card(ModelInfo model) => _ModelCard(
      key: ValueKey('${model.provider}\u0000${model.id}'),
      model: model,
      selected: selected?.id == model.id && selected?.provider == model.provider,
      onTap: onPick == null ? null : () => onPick!(model),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < models.length; i += 2) ...[
          if (i > 0) const SizedBox(height: gap),
          if (i + 1 < models.length)
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: card(models[i])),
                  const SizedBox(width: gap),
                  Expanded(child: card(models[i + 1])),
                ],
              ),
            )
          else
            card(models[i]),
        ],
      ],
    );
  }
}

/// 一张模型卡:短名(最多两行)+ 一行描述。选中时卡面染主色浅色背景、
/// 描一圈主色细边——单选靠底色和边框区分,不用勾选圈。
class _ModelCard extends StatelessWidget {
  const _ModelCard({super.key, required this.model, required this.selected, required this.onTap});

  final ModelInfo model;
  final bool selected;
  final VoidCallback? onTap;

  static const radius = BorderRadius.all(Radius.circular(AppShape.lg));

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final dsh = DshColors.of(context);
    final dark = theme.brightness == Brightness.dark;
    final description = model.description?.trim();
    final name = shortModelName(model.name);
    final duration = AppMotion.of(context, AppMotion.quick);
    return Semantics(
      button: true,
      enabled: onTap != null,
      selected: selected,
      inMutuallyExclusiveGroup: true,
      label: description == null || description.isEmpty ? name : context.l10n.viewDescribedValue(name, description),
      onTap: onTap,
      excludeSemantics: true,
      child: Pressable(
        onTap: onTap,
        child: GlassSurface(
          tier: GlassTier.card,
          borderRadius: radius,
          child: AnimatedContainer(
            duration: duration,
            curve: AppMotion.std,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: ShapeDecoration(
              color: selected
                  ? colors.primary.withValues(alpha: dark ? 0.18 : 0.1)
                  : colors.primary.withValues(alpha: 0),
              shape: RoundedSuperellipseBorder(
                borderRadius: radius,
                side: BorderSide(
                  color: selected
                      ? colors.primary.withValues(alpha: dark ? 0.7 : 0.55)
                      : colors.primary.withValues(alpha: 0),
                  width: 1.5,
                ),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // 14 / two lines: the row leaves the name ~109 dp on a
                // 390 dp phone, so "GPT 5.6 Terra" at titleMedium's 16 was
                // cut after the first words.
                Text(
                  name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall?.copyWith(
                    height: 1.3,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  ),
                ),
                if (description != null && description.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(
                    description,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(color: dsh.textTertiary),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Room around an empty / failed catalog inside the sheet.
const _emptyPadding = EdgeInsets.fromLTRB(32, 16, 32, 8);

/// 目录还在路上:一颗安静的小环,高度和一排模型卡差不多,来了不跳。
class _Loading extends StatelessWidget {
  const _Loading();

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 120,
    child: Center(
      child: SizedBox.square(
        dimension: 20,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          strokeCap: StrokeCap.round,
          color: DshColors.of(context).textTertiary,
        ),
      ),
    ),
  );
}

/// 目录是空的:DSH 0.2.1 在没有可用凭据时不列任何模型。什么都没配就引导去填
/// DeepSeek 的 Key,或者添加别的渠道;配了还是空,多半是 Key 还没同步到引擎或者
/// 无效,去「模型渠道」看。
class _EmptyCatalog extends StatelessWidget {
  const _EmptyCatalog({required this.configured, this.failure});

  /// A DeepSeek key or a custom provider exists.
  final bool configured;
  final String? failure;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final failure = this.failure?.trim();
    void push(Widget page) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
    if (!configured) {
      return EmptyView(
        padding: _emptyPadding,
        icon: AppIcons.apiKey,
        title: l10n.viewModelKeyRequired,
        message: l10n.viewModelProvidersHint,
        action: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            FilledButton(
              onPressed: () => push(const ApiKeyPage(onboarding: false)),
              child: Text(l10n.viewModelEnterKey),
            ),
            const SizedBox(height: 4),
            TextButton(onPressed: () => push(const ProviderFormPage()), child: Text(l10n.viewModelAddProvider)),
          ],
        ),
      );
    }
    return EmptyView(
      padding: _emptyPadding,
      icon: AppIcons.noApiKey,
      title: l10n.viewModelNone,
      message: failure != null && failure.isNotEmpty ? failure : l10n.viewModelKeyHint,
      action: FilledButton(onPressed: () => push(const ProvidersPage()), child: Text(l10n.viewModelManageProviders)),
    );
  }
}
