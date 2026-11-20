import Foundation

// Read only authored dimensions. Measuring table layout after inserting a large
// image would report the expanded table, rather than the sender's intended width.
enum ImageSizing {
    static let javascript = #"""
        const dimensionRules = [];
        for (const style of sizingRoot.querySelectorAll('style')) {
            try {
                const sheet = new CSSStyleSheet();
                sheet.replaceSync(style.textContent);
                for (const rule of sheet.cssRules) {
                    if (rule.selectorText && rule.style) dimensionRules.push(rule);
                }
            } catch (_) {}
        }
        function pixels(value) {
            const m = String(value || '').trim().match(/^([0-9]+(?:\.[0-9]+)?)(px|pt|in|cm|mm)?$/i);
            if (!m) return 0;
            const factors = {px:1, pt:96/72, in:96, cm:96/2.54, mm:96/25.4};
            const n = Number(m[1]) * (factors[(m[2] || 'px').toLowerCase()] || 1);
            return n > 0 && n <= 100000 ? n : 0;
        }
        function authoredDimension(node, property) {
            let value = node.getAttribute(property) || '';
            for (const rule of dimensionRules) {
                try { if (node.matches(rule.selectorText) && rule.style[property]) value = rule.style[property]; } catch (_) {}
            }
            return pixels(node.style[property] || value);
        }
        function imageDimensions(node, naturalWidth = 0) {
            let cellLimit = false;
            let width = authoredDimension(node, 'width');
            let height = authoredDimension(node, 'height');
            // Signature images often have no size left after HTML conversion,
            // but their enclosing table cell still has an explicit narrow width.
            if (!width && !height) {
                const cell = node.closest('td,th');
                if (cell) {
                    width = authoredDimension(cell, 'width');
                    cellLimit = width > 0;
                    if (naturalWidth > 0 && width > 0) width = Math.min(width, naturalWidth);
                }
            }
            return [width, height, cellLimit];
        }
        """#
}
