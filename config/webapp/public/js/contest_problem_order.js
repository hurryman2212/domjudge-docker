/* Contest problem ordering is submitted with the existing contest form. */
(function () {
    'use strict';

    function initialize() {
        const table = document.querySelector('[data-contest-problem-table]');
        if (!table) {
            return;
        }
        const holder = table.tBodies[0];
        const form = table.closest('form');
        const status = form.querySelector('[data-problem-order-status]');
        const prototype = form.querySelector('[data-prototype]').textContent;
        let nextIndex = 0;
        let dragged = null;
        let originalRows = [];
        let dropped = false;

        function rows() {
            return Array.from(holder.rows);
        }

        function synchronize() {
            const current = rows();
            current.forEach(function (row, index) {
                row.querySelector('[data-problem-order]').value = index + 1;
                row.querySelector('[data-problem-position]').textContent = index + 1;
                row.querySelector('[data-problem-up]').disabled = index === 0;
                row.querySelector('[data-problem-down]').disabled = index === current.length - 1;
            });
        }

        function announce(row) {
            const label = row.querySelector('input[name$="[shortname]"]').value || 'Problem';
            status.textContent = label + ' is now in position ' + (rows().indexOf(row) + 1) + '. Save to apply.';
        }

        function move(row, direction) {
            const adjacent = direction < 0 ? row.previousElementSibling : row.nextElementSibling;
            if (!adjacent) {
                return;
            }
            holder.insertBefore(row, direction < 0 ? adjacent : adjacent.nextElementSibling);
            synchronize();
            row.querySelector('[data-problem-drag]').focus();
            announce(row);
        }

        // On a validation error Symfony keeps collection keys, which may contain
        // gaps. Find the next unused key instead of reusing the number of rows.
        rows().forEach(function (row) {
            const name = row.querySelector('[data-problem-order]').name;
            const match = name.match(/\[problems\]\[(\d+)\]/);
            if (match) {
                nextIndex = Math.max(nextIndex, Number(match[1]) + 1);
            }
        });

        // Re-display the submitted order after other fields fail validation.
        rows().sort(function (a, b) {
            const aOrder = Number(a.querySelector('[data-problem-order]').value) || Number.MAX_SAFE_INTEGER;
            const bOrder = Number(b.querySelector('[data-problem-order]').value) || Number.MAX_SAFE_INTEGER;
            return aOrder - bOrder;
        }).forEach(function (row) {
            holder.appendChild(row);
        });
        synchronize();

        table.addEventListener('click', function (event) {
            const button = event.target.closest('button');
            if (!button) {
                return;
            }
            const row = button.closest('tr');
            if (button.hasAttribute('data-problem-up')) {
                move(row, -1);
            } else if (button.hasAttribute('data-problem-down')) {
                move(row, 1);
            } else if (button.hasAttribute('data-delete')) {
                row.remove();
                synchronize();
                status.textContent = 'Problem removed. Save to apply.';
            } else if (button.hasAttribute('data-add')) {
                holder.insertAdjacentHTML('beforeend', prototype.replace(/__name__/g, nextIndex++));
                synchronize();
                if (typeof window.bindColor === 'function') {
                    window.bindColor();
                }
                const added = holder.lastElementChild;
                added.querySelector('select').focus();
                announce(added);
            }
        });

        holder.addEventListener('keydown', function (event) {
            if (!event.target.closest('[data-problem-drag]')) {
                return;
            }
            if (event.key === 'ArrowUp' || event.key === 'ArrowDown') {
                event.preventDefault();
                move(event.target.closest('tr'), event.key === 'ArrowUp' ? -1 : 1);
            }
        });

        holder.addEventListener('dragstart', function (event) {
            const handle = event.target.closest('[data-problem-drag]');
            if (!handle) {
                event.preventDefault();
                return;
            }
            dragged = handle.closest('tr');
            originalRows = rows();
            dropped = false;
            event.dataTransfer.effectAllowed = 'move';
            event.dataTransfer.setData('text/plain', 'contest-problem');
            dragged.classList.add('opacity-50');
        });

        holder.addEventListener('dragover', function (event) {
            if (!dragged) {
                return;
            }
            event.preventDefault();
            event.dataTransfer.dropEffect = 'move';
            const target = event.target.closest('tr');
            if (!target || target === dragged || target.parentElement !== holder) {
                return;
            }
            const bounds = target.getBoundingClientRect();
            const before = event.clientY < bounds.top + bounds.height / 2;
            holder.insertBefore(dragged, before ? target : target.nextElementSibling);
            synchronize();
        });

        holder.addEventListener('drop', function (event) {
            if (dragged) {
                event.preventDefault();
                dropped = true;
            }
        });

        holder.addEventListener('dragend', function () {
            if (!dragged) {
                return;
            }
            if (!dropped) {
                originalRows.forEach(function (row) {
                    holder.appendChild(row);
                });
            }
            dragged.classList.remove('opacity-50');
            synchronize();
            dragged.querySelector('[data-problem-drag]').focus();
            announce(dragged);
            dragged = null;
        });

        form.addEventListener('submit', synchronize);
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', initialize);
    } else {
        initialize();
    }
}());
