'use strict';
'require view';
'require rpc';
'require ui';
'require poll';
'require uci';

var status = rpc.declare({ object: 'yume-simhub', method: 'status', expect: {} });
var settings = rpc.declare({ object: 'yume-simhub', method: 'settings', expect: {} });
var configure = rpc.declare({ object: 'yume-simhub', method: 'configure', params: ['token', 'enabled'], expect: {} });
var save = rpc.declare({ object: 'yume-simhub', method: 'save_settings', params: ['settings'], expect: {} });
var switchDevice = rpc.declare({ object: 'yume-simhub', method: 'switch', params: ['device'], expect: {} });
var service = rpc.declare({ object: 'yume-simhub', method: 'service', params: ['action'], expect: {} });
function checked(result) {
    if (result.error) throw new Error(result.error);
    return result;
}
function perform(fn) {
    return Promise.resolve().then(fn).then(checked).catch(function(error) {
        ui.addNotification(null, E('p', {}, error.message), 'error');
    });
}
function row(label, input) {
    return E('div', { 'class': 'cbi-value' }, [
        E('label', { 'class': 'cbi-value-title' }, label),
        E('div', { 'class': 'cbi-value-field' }, [input])
    ]);
}
function text(value, password) {
    return E('input', { 'class': 'cbi-input-text', type: password ? 'password' : 'text', value: value || '', autocomplete: password ? 'new-password' : 'off' });
}
function flag(value) { return E('input', { type: 'checkbox', checked: !!value }); }
return view.extend({
    load: function() {
        return Promise.all([status(), settings().catch(function() { return {}; }), uci.load('yume-simhub')]);
    },
    render: function(data) {
        var state = data[0], config = data[1].settings || {}, inputs = {};
        var summary = E('p');
        var devices = E('div');
        function update(value) {
            var local = value.local || {}, runtime = value.runtime || {}, lease = runtime.lease || {};
            summary.textContent = value.error || (local.runtimeState === 'standby' ? _('Standby: waiting for runtime ownership') :
                _('Module') + ': ' + (local.modemConnected ? _('Connected') : _('Disconnected')) + ' · SIP: ' + (local.sipRegistered ? _('Registered') : _('Offline')) + ' · ' + (local.busy ? _('In call') : _('Idle')));
            devices.replaceChildren();
            (runtime.devices || []).forEach(function(device) {
                var active = lease.owner === device.id && lease.expires > Date.now();
                var button = E('button', { 'class': 'cbi-button', disabled: active || local.busy,
                    click: function() { perform(function() { return switchDevice(device.id); }); }
                }, active ? _('Active') : _('Switch to this device'));
                devices.appendChild(E('p', {}, [E('span', {}, device.label + ' (' + device.platform + ') '), button]));
            });
        }
        update(state);
        poll.add(function() { return status().then(update); }, 10);
        var token = text('', true), enabled = flag(uci.get('yume-simhub', 'main', 'enabled') === '1');
        var connection = E('div', { 'class': 'cbi-section' }, [
            E('h3', {}, _('Connection')),
            E('p', {}, _('Pair once using the same cloud client credential as the Mac app. Business settings are shared in the cloud database.')),
            row(_('Client credential (leave blank to keep)'), token), row(_('Start automatically'), enabled),
            E('button', { 'class': 'cbi-button cbi-button-apply', click: function() {
                perform(function() { return configure(token.value, enabled.checked).then(function(r) { checked(r); token.value = ''; window.location.reload(); return r; }); });
            } }, _('Save connection'))
        ]);
        function input(key, label, value, kind) {
            var control = kind === 'flag' ? flag(value) : text(value, kind === 'secret');
            inputs[key] = { control: control, kind: kind };
            return row(label, control);
        }
        var language = E('select', { 'class': 'cbi-input-select' }, ['en','zh-Hans','zh-Hant','ja','fr'].map(function(lang) {
            return E('option', { value: lang, selected: config.serviceLanguage === lang }, lang);
        }));
        inputs.serviceLanguage = { control: language };
        var shared = E('div', { 'class': 'cbi-section' }, [
            E('h3', {}, _('Shared cloud settings')),
            row(_('Telephone and notification language'), language),
            input('inboundEnabled', _('Forward incoming calls'), config.inboundEnabled, 'flag'),
            input('forwardTo', _('Forward to (E.164)'), config.forwardTo),
            input('forwardConfirmEnabled', _('Press 1 to confirm forwarding'), config.forwardConfirmEnabled, 'flag'),
            input('outboundEnabled', _('Enable SIP outbound calls'), config.outboundEnabled, 'flag'),
            input('sipDomain', _('SIP domain'), config.sipDomain),
            input('sipUser', _('SIP user'), config.sipUser),
            input('sipPassword', _('SIP password (leave blank to keep)'), '', 'secret'),
            input('gotifyUrl', _('Gotify URL'), config.gotifyUrl),
            input('gotifyToken', _('Gotify token (leave blank to keep)'), '', 'secret'),
            input('emailEnabled', _('Enable email to SMS'), config.emailEnabled, 'flag'),
            input('allowedSenders', _('Allowed email senders (comma separated)'), (config.allowedSenders || []).join(', '), 'list'),
            E('button', { 'class': 'cbi-button cbi-button-apply', disabled: !state.configured || !data[1].settings, click: function() {
                var values = {};
                Object.keys(inputs).forEach(function(key) {
                    var item = inputs[key], value = item.kind === 'flag' ? item.control.checked : item.control.value;
                    if (item.kind === 'list') value = value.split(',').map(function(s) { return s.trim(); }).filter(Boolean);
                    if (item.kind !== 'secret' || value) values[key] = value;
                });
                perform(function() { return save(values).then(function(r) {
                    checked(r); Object.keys(inputs).forEach(function(key) { if (inputs[key].kind === 'secret') inputs[key].control.value = ''; });
                    ui.addNotification(null, E('p', {}, _('Cloud settings saved.')), 'info');return r;
                }); });
            } }, _('Save cloud settings'))
        ]);
        return E('div', {}, [E('h2', {}, 'Yume SIM Hub'), E('p', {}, (state.version || {}).version + ' · Build ' + (state.version || {}).build), summary, devices, connection, shared,
            E('button', { 'class': 'cbi-button', click: function() { perform(function() { return service('restart'); }); } }, _('Restart service')),
            E('button', { 'class': 'cbi-button', click: function() { perform(function() { return service('stop'); }); } }, _('Stop service'))]);
    },
    handleSaveApply: null, handleSave: null, handleReset: null
});
