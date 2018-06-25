// Copyright (c) 2013, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library route.browser;

import 'dart:async';
import 'dart:collection';
import 'dart:html';

import 'package:logging/logging.dart';

import 'url_pattern.dart';
import 'route.dart';

export 'url_pattern.dart';
export 'route.dart';

typedef Handler(final String path);

typedef void EventHandler(final Event e);

/// Stores a set of [UrlPattern] to [Handler] associations and provides methods
/// for calling a handler for a URL path, listening to [Window] history events,
/// and creating HTML event handlers that navigate to a URL.
class Router {
    final _logger = new Logger('route.client');

    final LinkedHashMap<UrlPattern, Route> _handlers;
    final bool useFragment;

    bool _listen = false;

    StreamController<RouteEnterEvent> _onEnter;
    StreamController<RouteErrorEvent> _onError;

    /// [useFragment] determines whether this Router uses pure paths with
    /// [History.pushState] or paths + fragments and [Location.assign]. The default
    /// value is null which then determines the behavior based on
    /// [History.supportsState].
    Router({final bool useFragment: true})
        : _handlers = new LinkedHashMap<UrlPattern, Route>(),
            useFragment = (useFragment == null) ? !History.supportsState : useFragment;

    /// Registers a function that will be invoked when the router handles a URL
    /// that matches [pattern].
    void addRoute({final String name, final path, final RouteEnterCallback enter }) {
        final Route route = (path is UrlPattern)
            ? new Route(name, path, enter)
            : new Route(name, new UrlPattern(path.toString()), enter);

        _logger.finest('addHandler ${route.title} -> ${route.urlPattern.pattern}');
        _handlers[route.urlPattern] = route;
    }

    /// Listens for window history events and invokes the router. On older
    /// browsers the hashChange event is used instead.
    void listen({final bool ignoreClick: false}) {
        _logger.finest('listen ignoreClick=$ignoreClick useFragment=$useFragment');
        if (_listen) {
            throw new StateError('listen should be called once.');
        }

        _listen = true;
        if (useFragment) {
            window.onHashChange.listen((_) {
                final path = '${window.location.pathname}${window.location.hash}';
                _logger.finest('onHashChange handle($path)');
                return _handle(path);
            });
            _handle('${window.location.pathname}${window.location.hash}');
        }
        else {
            window.onPopState.listen((_) {
                final path = '${window.location.pathname}${window.location.hash}';
                _logger.finest('onPopState handle($path)');
                _handle(path);
            });
        }

        if (!ignoreClick) {
            window.onClick.listen((e) {
                if (e.target is AnchorElement) {
                    final AnchorElement anchor = e.target;
                    if (anchor.host == window.location.host) {
                        final fragment = (anchor.hash == '') ? '' : '${anchor.hash}';
                        gotoPath("${anchor.pathname}$fragment", anchor.title);
                        e.preventDefault();
                    }
                }
            });
        }
    }

    /// Navigates the browser to the path produced by [urlPattern] with [params] by calling
    /// [History.pushState], then invokes the handler associated with [urlPattern].
    ///
    /// On older browsers [Location.assign] is used instead with the fragment
    /// version of the UrlPattern.
    void gotoUrl(final UrlPattern urlPattern, final List params, final String title) {
        if (_handlers.containsKey(urlPattern)) {
            final fixedPath = urlPattern.expand(params, useFragment: useFragment);

            _go(fixedPath, title);
            _fire(new RouteEnterEvent(_handlers[urlPattern], fixedPath,  params));
        }
        else {
            throw new ArgumentError('Unknown URL pattern: $urlPattern');
        }
    }

    void gotoPath(final String path, final String title) {
        _logger.finest('gotoPath $path');
        final urlPattern = _getUrl(path);
        if (urlPattern != null) {
            _go(path, title);
            // If useFragment, onHashChange will call handle for us.
            if (!_listen || !useFragment) {
                final List<String> params = urlPattern.parse(path);
                final fixedPath = urlPattern.expand(params, useFragment: useFragment);

                _fire(new RouteEnterEvent(_handlers[urlPattern], fixedPath,  params));
            }
        }
    }

    ///  Returns an [Event] handler suitable for use as a click handler on [:<a>:]
    ///  elements. The handler reverses [url] with [args] and uses [window.pushState]
    ///  with [title] to change the user visible URL without navigating to it.
    ///  [Event.preventDefault] is called to stop the default behavior. Then the
    ///  handler associated with [url] is invoked with [args].
    EventHandler clickHandler(final UrlPattern url, final List args, final String title) =>
            (final Event e) {
            e.preventDefault();
            gotoUrl(url, args, title);
        };

    Stream<RouteEnterEvent> get onEnter {
        if (_onEnter == null) {
            _onEnter = new StreamController<RouteEnterEvent>.broadcast(onCancel: () => _onEnter = null);
        }
        return _onEnter.stream;
    }

    Stream<RouteErrorEvent> get onError {
        if (_onError == null) {
            _onError = new StreamController<RouteErrorEvent>.broadcast(onCancel: () => _onError = null);
        }
        return _onError.stream;
    }

    // - private -------------------------------------------------------------------------------------

    ///  Finds a matching [UrlPattern] added with [addRoute], parses the path
    ///  and invokes the associated callback.
    ///
    ///  This method does not perform any navigation, [go] should be used for that.
    ///  This method is used to invoke a handler after some other code navigates the
    ///  window, such as [listen].
    ///
    ///  If the UrlPattern contains a fragment (#), the handler is always called
    ///  with the path version of the URL by converting the # to a /.
    void _handle(final String path) {
        _logger.finest('handle $path');
        final url = _getUrl(path);
        if (url != null) {
            final List<String> params = url.parse(path);
            final fixedPath = url.expand(params, useFragment: useFragment);

            _fire(new RouteEnterEvent(_handlers[url], fixedPath,  params));
        }
        else {
            _logger.info("Unhandled path: $path");
        }
    }

    UrlPattern _getUrl(final path) {
        var matches = _handlers.keys.where(( url) => url.matches(path));
        if (matches.isEmpty) {

            final error = new ArgumentError("No handler found for $path");
            if(true == _onError?.hasListener) {
                _fire(new RouteErrorEvent(error, path));
                return null;
            } else {
                throw error;
            }
        }
        return matches.first;
    }

    void _go(final String path, String title) {
        title = (title == null) ? '' : title;
        if (useFragment) {
            window.location.assign(path);
            (window.document as HtmlDocument).title = title;
        }
        else {
            window.history.pushState(null, title, path);
        }
    }

    void _fire(final RouteEvent event) {
        // _logger.info("onChange: ${_onChange}, hasListeners: ${_onChange ?.hasListener}");
        if(event is RouteErrorEvent) {
            if (true == _onError?.hasListener) {
                _onError.add(event);
            }
        }
        else if(event is RouteEnterEvent) {
            if (true == _onEnter?.hasListener) {
                _onEnter.add(event);
            }
            // Call callback defined with route
            event.route.onEnter(event);
        }
        else {
            throw ArgumentError("Undefined RouteEvent! ($event)");
        }
    }
}
