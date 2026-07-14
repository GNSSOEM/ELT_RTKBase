/*!
 * combobox.js — select со свободным вводом (combobox) на Bootstrap 4.
 * Использует только CSS-классы Bootstrap (input-group + dropdown-menu),
 * JS — vanilla, без зависимостей. Пример использования: см. combobox.md.
 */
(function (global) {
  'use strict';

  var DEFAULTS = {
    options: [],
    emptyText: null,
    maxHeight: 240
  };

  function fire(el, type) {
    var ev;
    try {
      ev = new Event(type, { bubbles: true });
    } catch (e) {
      ev = document.createEvent('Event');
      ev.initEvent(type, true, false);
    }
    el.dispatchEvent(ev);
  }

  /**
   * Combobox(input, opts) — оборачивает готовый <input class="form-control">
   * в выпадающий список с фильтрацией и возможностью ввода своего значения.
   *
   * input — элемент <input> или CSS-селектор.
   * opts:
   *   options   — массив строк для списка (по умолчанию []);
   *   emptyText — текст-заглушка, когда фильтр ничего не нашёл
   *               (по умолчанию null — список просто закрывается);
   *   maxHeight — максимальная высота списка в px, дальше прокрутка (240).
   */
  function Combobox(input, opts) {
    if (!(this instanceof Combobox)) return new Combobox(input, opts);
    if (typeof input === 'string') input = document.querySelector(input);
    if (!input || input.tagName !== 'INPUT') throw new Error('Combobox: нужен элемент <input>');

    var o = {}, k;
    for (k in DEFAULTS) o[k] = DEFAULTS[k];
    for (k in (opts || {})) o[k] = opts[k];

    this.input = input;
    this.options = (o.options || []).slice();
    this._emptyText = o.emptyText;
    this._active = -1;

    // строим обвязку вокруг инпута:
    // <div class="dropdown combobox">
    //   <div class="input-group"> [input] <кнопка-стрелка> </div>
    //   <div class="dropdown-menu w-100"></div>
    // </div>
    var wrap = document.createElement('div');
    wrap.className = 'dropdown combobox';
    input.parentNode.insertBefore(wrap, input);

    var group = document.createElement('div');
    group.className = 'input-group';
    wrap.appendChild(group);
    group.appendChild(input);

    var append = document.createElement('div');
    append.className = 'input-group-append';
    var caret = document.createElement('button');
    caret.type = 'button';
    caret.tabIndex = -1;
    caret.className = 'btn btn-outline-secondary dropdown-toggle';
    caret.setAttribute('aria-label', 'Show list');
    append.appendChild(caret);
    group.appendChild(append);

    var menu = document.createElement('div');
    menu.className = 'dropdown-menu w-100';
    menu.setAttribute('role', 'listbox');
    if (o.maxHeight) {
      menu.style.maxHeight = o.maxHeight + 'px';
      menu.style.overflowY = 'auto';
    }
    wrap.appendChild(menu);

    input.autocomplete = 'off';
    input.setAttribute('role', 'combobox');
    input.setAttribute('aria-expanded', 'false');

    this._wrap = wrap;
    this._menu = menu;
    this._caret = caret;

    var self = this;
    // клик по непустому инпуту список не открывает (не мешает редактировать
    // текст / ставить курсор), а по пустому — открывает, как по стрелке
    this._onClick = function () { if (!self.isOpen() && !self.input.value) self.open(); };
    this._onInput = function () { self.open(self.input.value); };
    this._onKeydown = function (e) { self._keydown(e); };
    this._onCaret = function () {
      if (self.isOpen()) { self.close(); } else { self.input.focus(); self.open(); }
    };
    this._onDocClick = function (e) { if (!self._wrap.contains(e.target)) self.close(); };

    input.addEventListener('click', this._onClick);
    input.addEventListener('input', this._onInput);
    input.addEventListener('keydown', this._onKeydown);
    caret.addEventListener('click', this._onCaret);
    document.addEventListener('click', this._onDocClick);
  }

  Combobox.prototype._items = function () {
    return this._menu.querySelectorAll('.dropdown-item:not(.disabled)');
  };

  Combobox.prototype._render = function (filter) {
    var f = (filter || '').toLowerCase();
    var self = this;
    var matched = this.options.filter(function (o) {
      return !f || o.toLowerCase().indexOf(f) !== -1;
    });
    this._menu.innerHTML = '';
    this._active = -1;
    if (!matched.length) {
      if (this._emptyText) {
        var empty = document.createElement('span');
        empty.className = 'dropdown-item disabled text-muted';
        empty.textContent = this._emptyText;
        this._menu.appendChild(empty);
      }
      return;
    }
    matched.forEach(function (o) {
      var b = document.createElement('button');
      b.type = 'button';
      b.className = 'dropdown-item' + (o === self.input.value ? ' active' : '');
      b.setAttribute('role', 'option');
      b.textContent = o;
      b.addEventListener('click', function () { self._pick(o); });
      self._menu.appendChild(b);
    });
  };

  Combobox.prototype.isOpen = function () {
    return this._menu.classList.contains('show');
  };

  // open() — показать весь список; open(filter) — отфильтрованный по подстроке
  Combobox.prototype.open = function (filter) {
    this._render(filter);
    if (!this._menu.childNodes.length) { this.close(); return; }
    this._menu.classList.add('show');
    this.input.setAttribute('aria-expanded', 'true');
  };

  Combobox.prototype.close = function () {
    this._menu.classList.remove('show');
    this.input.setAttribute('aria-expanded', 'false');
    this._active = -1;
  };

  Combobox.prototype._pick = function (v) {
    this.input.value = v;
    this.close();
    this.input.focus();
    fire(this.input, 'input');
    fire(this.input, 'change');
  };

  Combobox.prototype._move = function (delta) {
    var items = this._items();
    if (!items.length) return;
    this._active = (this._active + delta + items.length) % items.length;
    for (var i = 0; i < items.length; i++) {
      items[i].classList.toggle('active', i === this._active);
    }
    items[this._active].scrollIntoView({ block: 'nearest' });
  };

  Combobox.prototype._keydown = function (e) {
    var key = e.key;
    if (key === 'ArrowDown' || key === 'ArrowUp') {
      if (!this.isOpen()) this.open(this.input.value);
      this._move(key === 'ArrowDown' ? 1 : -1);
      e.preventDefault();
    } else if (key === 'Enter') {
      // пока список открыт, Enter выбирает пункт (или закрывает список),
      // а не отправляет форму вокруг инпута
      if (this.isOpen()) {
        var items = this._items();
        if (this._active >= 0 && items[this._active]) {
          this._pick(items[this._active].textContent);
        } else {
          this.close();
        }
        e.preventDefault();
      }
    } else if (key === 'Escape') {
      this.close();
    }
  };

  Combobox.prototype.setOptions = function (options) {
    this.options = (options || []).slice();
    if (this.isOpen()) this.open(this.input.value);
  };

  Combobox.prototype.getValue = function () {
    return this.input.value;
  };

  Combobox.prototype.setValue = function (v) {
    this.input.value = v == null ? '' : String(v);
  };

  // возвращает инпут на место и снимает все обработчики
  Combobox.prototype.destroy = function () {
    var input = this.input;
    input.removeEventListener('click', this._onClick);
    input.removeEventListener('input', this._onInput);
    input.removeEventListener('keydown', this._onKeydown);
    this._caret.removeEventListener('click', this._onCaret);
    document.removeEventListener('click', this._onDocClick);
    this._wrap.parentNode.insertBefore(input, this._wrap);
    this._wrap.parentNode.removeChild(this._wrap);
    input.removeAttribute('role');
    input.removeAttribute('aria-expanded');
  };

  global.Combobox = Combobox;

  // необязательная jQuery-обвязка: $('#my-input').combobox({options: [...]})
  if (global.jQuery) {
    global.jQuery.fn.combobox = function (opts) {
      return this.each(function () {
        var $el = global.jQuery(this);
        if (!$el.data('combobox')) $el.data('combobox', new Combobox(this, opts));
      });
    };
  }
})(window);
