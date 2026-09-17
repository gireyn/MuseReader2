import 'package:flutter/material.dart';

/// Checkbox-button used by the library header (内部标题) and the reader
/// (熄屏不打断下一首): a square tick on the left of the label where the whole
/// button toggles — the square itself is not separately interactive.
class MuseToggleButton extends StatelessWidget {
  const MuseToggleButton({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.tooltip,
    this.dense = false,
  });

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;
  final String? tooltip;

  /// Compact pill sized like the loop-mode item (used in the reader).
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (dense) return _buildDense(context, theme);
    final button = Semantics(
      checked: value,
      label: label,
      child: OutlinedButton(
        onPressed: () => onChanged(!value),
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          foregroundColor: theme.colorScheme.onSurface,
          side: BorderSide(
            color: value
                ? theme.colorScheme.primary
                : theme.colorScheme.outlineVariant,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IgnorePointer(
              child: Checkbox(
                value: value,
                onChanged: (_) {},
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                side: BorderSide(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ],
        ),
      ),
    );
    if (tooltip == null) return button;
    return Tooltip(message: tooltip!, child: button);
  }

  /// Same footprint as the 循环模式 pill: small square + label.
  Widget _buildDense(BuildContext context, ThemeData theme) {
    final color = theme.colorScheme.onSurfaceVariant;
    final pill = Semantics(
      checked: value,
      label: label,
      child: InkWell(
        onTap: () => onChanged(!value),
        borderRadius: BorderRadius.circular(999),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: value
                  ? theme.colorScheme.primary
                  : theme.colorScheme.outlineVariant,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                value
                    ? Icons.check_box_rounded
                    : Icons.check_box_outline_blank_rounded,
                size: 18,
                color: value ? theme.colorScheme.primary : color,
              ),
              const SizedBox(width: 6),
              Text(
                label,
                maxLines: 1,
                style: theme.textTheme.labelMedium?.copyWith(color: color),
              ),
            ],
          ),
        ),
      ),
    );
    if (tooltip == null) return pill;
    return Tooltip(message: tooltip!, child: pill);
  }
}
