/****************************************************************************
**
** Copyright (C) 2016 The Qt Company Ltd.
** Contact: https://www.qt.io/licensing/
**
** This file is part of the plugins of the Qt Toolkit.
**
** $QT_BEGIN_LICENSE:LGPL$
** Commercial License Usage
** Licensees holding valid commercial Qt licenses may use this file in
** accordance with the commercial license agreement provided with the
** Software or, alternatively, in accordance with the terms contained in
** a written agreement between you and The Qt Company. For licensing terms
** and conditions see https://www.qt.io/terms-conditions. For further
** information use the contact form at https://www.qt.io/contact-us.
**
** GNU Lesser General Public License Usage
** Alternatively, this file may be used under the terms of the GNU Lesser
** General Public License version 3 as published by the Free Software
** Foundation and appearing in the file LICENSE.LGPL3 included in the
** packaging of this file. Please review the following information to
** ensure the GNU Lesser General Public License version 3 requirements
** will be met: https://www.gnu.org/licenses/lgpl-3.0.html.
**
** GNU General Public License Usage
** Alternatively, this file may be used under the terms of the GNU
** General Public License version 2.0 or (at your option) the GNU General
** Public license version 3 or any later version approved by the KDE Free
** Qt Foundation. The licenses are as published by the Free Software
** Foundation and appearing in the file LICENSE.GPL2 and LICENSE.GPL3
** included in the packaging of this file. Please review the following
** information to ensure the GNU General Public License requirements will
** be met: https://www.gnu.org/licenses/gpl-3.0.html.
**
** $QT_END_LICENSE$
**
****************************************************************************/

// Based on Qt 5.15.2's minimal QPA integration. The minimal plugin is used
// instead of Qt's full Android QPA, so Android's system-font database must be
// selected explicitly while retaining FreeType application-font support for
// the bundled MuseScore fonts. Other platforms keep the upstream behavior.

#include "qminimalintegration.h"
#include "qminimalbackingstore.h"

#include <QtGui/private/qpixmap_raster_p.h>
#include <QtGui/private/qguiapplication_p.h>
#include <qpa/qplatformwindow.h>
#include <qpa/qwindowsysteminterface.h>

#include <QtFontDatabaseSupport/private/qfreetypefontdatabase_p.h>
#if defined(Q_OS_ANDROID)
// The minimal QPA plugin does not use Qt's Android platform integration, so
// it must provide the Android system-font database itself.  In particular,
// this database scans /system/fonts (including Noto Sans CJK) and supplies the
// writing-system metadata Qt needs for per-glyph fallback.
#include "qandroidplatformfontdatabase.h"
#endif
#if defined(Q_OS_WINRT)
#include <QtFontDatabaseSupport/private/qwinrtfontdatabase_p.h>
#elif defined(Q_OS_WIN)
#include <QtFontDatabaseSupport/private/qwindowsfontdatabase_p.h>
#if QT_CONFIG(freetype)
#include <QtFontDatabaseSupport/private/qwindowsfontdatabase_ft_p.h>
#endif
#elif defined(Q_OS_DARWIN)
#include <QtFontDatabaseSupport/private/qcoretextfontdatabase_p.h>
#endif

#if QT_CONFIG(fontconfig)
#include <QtFontDatabaseSupport/private/qgenericunixfontdatabase_p.h>
#include <qpa/qplatformfontdatabase.h>
#endif

#if QT_CONFIG(freetype)
#include <QtFontDatabaseSupport/private/qfontengine_ft_p.h>
#endif

#if !defined(Q_OS_WIN)
#include <QtEventDispatcherSupport/private/qgenericunixeventdispatcher_p.h>
#elif defined(Q_OS_WINRT)
#include <QtCore/private/qeventdispatcher_winrt_p.h>
#else
#include <QtCore/private/qeventdispatcher_win_p.h>
#endif

QT_BEGIN_NAMESPACE

class QCoreTextFontEngine;

static const char debugBackingStoreEnvironmentVariable[] =
    "QT_DEBUG_BACKINGSTORE";

static inline unsigned parseOptions(const QStringList& paramList) {
  unsigned options = 0;
  for (const QString& param : paramList) {
    if (param == QLatin1String("enable_fonts"))
      options |= QMinimalIntegration::EnableFonts;
    else if (param == QLatin1String("freetype"))
      options |= QMinimalIntegration::FreeTypeFontDatabase;
    else if (param == QLatin1String("fontconfig"))
      options |= QMinimalIntegration::FontconfigDatabase;
  }
  return options;
}

QMinimalIntegration::QMinimalIntegration(const QStringList& parameters)
    : m_fontDatabase(nullptr), m_options(parseOptions(parameters)) {
  if (qEnvironmentVariableIsSet(debugBackingStoreEnvironmentVariable) &&
      qEnvironmentVariableIntValue(debugBackingStoreEnvironmentVariable) > 0) {
    m_options |= DebugBackingStore | EnableFonts;
  }

  m_primaryScreen = new QMinimalScreen();
  m_primaryScreen->mGeometry = QRect(0, 0, 240, 320);
  m_primaryScreen->mDepth = 32;
  m_primaryScreen->mFormat = QImage::Format_ARGB32_Premultiplied;
  QWindowSystemInterface::handleScreenAdded(m_primaryScreen);
}

QMinimalIntegration::~QMinimalIntegration() {
  QWindowSystemInterface::handleScreenRemoved(m_primaryScreen);
  delete m_fontDatabase;
}

bool QMinimalIntegration::hasCapability(
    QPlatformIntegration::Capability capability) const {
  switch (capability) {
    case ThreadedPixmaps:
    case MultipleWindows:
      return true;
    default:
      return QPlatformIntegration::hasCapability(capability);
  }
}

class DummyFontDatabase : public QPlatformFontDatabase {
 public:
  void populateFontDatabase() override {}
};

QPlatformFontDatabase* QMinimalIntegration::fontDatabase() const {
  if (!m_fontDatabase && (m_options & EnableFonts)) {
#if defined(Q_OS_WINRT)
    m_fontDatabase = new QWinRTFontDatabase;
#elif defined(Q_OS_WIN)
    if (m_options & FreeTypeFontDatabase) {
#if QT_CONFIG(freetype)
      m_fontDatabase = new QWindowsFontDatabaseFT;
#endif
    } else {
      m_fontDatabase = new QWindowsFontDatabase;
    }
#elif defined(Q_OS_ANDROID)
    // QFreeTypeFontDatabase's default directory is Qt's installation
    // directory, which is empty in the bundled Android deployment.  The
    // Android implementation scans /system/fonts and keeps application-font
    // registration (used below for MuseScore's SMuFL/text fonts) intact.
    if (m_options & FreeTypeFontDatabase) {
#if QT_CONFIG(freetype)
      m_fontDatabase = new QAndroidPlatformFontDatabase;
#endif
    }
#elif defined(Q_OS_DARWIN)
    if (!(m_options & FontconfigDatabase)) {
      if (m_options & FreeTypeFontDatabase) {
#if QT_CONFIG(freetype)
        m_fontDatabase =
            new QCoreTextFontDatabaseEngineFactory<QFontEngineFT>;
#endif
      } else {
        m_fontDatabase =
            new QCoreTextFontDatabaseEngineFactory<QCoreTextFontEngine>;
      }
    }
#endif

    if (!m_fontDatabase) {
#if QT_CONFIG(fontconfig)
      m_fontDatabase = new QGenericUnixFontDatabase;
#else
      m_fontDatabase = QPlatformIntegration::fontDatabase();
#endif
    }
  }
  if (!m_fontDatabase) m_fontDatabase = new DummyFontDatabase;
  return m_fontDatabase;
}

QPlatformWindow* QMinimalIntegration::createPlatformWindow(
    QWindow* window) const {
  Q_UNUSED(window)
  QPlatformWindow* platformWindow = new QPlatformWindow(window);
  platformWindow->requestActivateWindow();
  return platformWindow;
}

QPlatformBackingStore* QMinimalIntegration::createPlatformBackingStore(
    QWindow* window) const {
  return new QMinimalBackingStore(window);
}

QAbstractEventDispatcher* QMinimalIntegration::createEventDispatcher() const {
#ifdef Q_OS_WIN
#ifndef Q_OS_WINRT
  return new QEventDispatcherWin32;
#else
  return new QEventDispatcherWinRT;
#endif
#else
  return createUnixEventDispatcher();
#endif
}

QMinimalIntegration* QMinimalIntegration::instance() {
  return static_cast<QMinimalIntegration*>(
      QGuiApplicationPrivate::platformIntegration());
}

QT_END_NAMESPACE
