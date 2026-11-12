// Copyright 2010-2018, Google Inc.
// All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are
// met:
//
//     * Redistributions of source code must retain the above copyright
// notice, this list of conditions and the following disclaimer.
//     * Redistributions in binary form must reproduce the above
// copyright notice, this list of conditions and the following disclaimer
// in the documentation and/or other materials provided with the
// distribution.
//     * Neither the name of Google Inc. nor the names of its
// contributors may be used to endorse or promote products derived from
// this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
// "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
// LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
// A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
// OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
// SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
// LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
// DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
// THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

package org.futo.inputmethod.nativelib.mozc.emoji;

import org.futo.inputmethod.nativelib.mozc.MozcUtil.TelephonyManagerInterface;

import com.google.common.base.MoreObjects;
import com.google.common.base.Preconditions;

import java.util.Collections;
import java.util.HashMap;
import java.util.HashSet;
import java.util.Map;
import java.util.Set;

/**
 * Providers whose emoji set MechaMozc supports.
 *
 */
public enum EmojiProviderType {

  /**
   * Place holder for following situations.
   * <ul>
   * <li>Provider detection is failed.
   * <li>A user select this item explicitly on the preference screen.
   * <li>Emoji is disabled by spec.
   * </ul>
   * If a user invokes Emoji screen on symbol input view, provider chooser dialog will be shown.
   * If Emoji is disabled by spec, Emoji screen itself should be suppressed.
   *
   * Note:
   * <ul>
   * <li>NONE is just a default value. User should update it to use Emoji.
   * <li>Unicode 6.0 Emoji is available even if DOCOMO, KDDI and SOFTBANK.
   * </ul>
   */
  NONE((byte) 0),
  DOCOMO((byte) 1),
  KDDI((byte) 2),
  SOFTBANK((byte) 4),
  UNICODE((byte) 8),
  ;

  private static final Map<String, EmojiProviderType> NETWORK_OPERATOR_MAP;
  private static final Set<String> NAME_SET;

  private final byte bitMask;

  static {
    // The key is "Mobile Country Code" + "Mobile Network Code".
    // Note that if the network operator uses MVNO (Mobile Virtual Network Operator),
    // the network operator provided by TelephonyManager would be the one of their partner's.
    Map<String, EmojiProviderType> networkOperatorMap = new HashMap<String, EmojiProviderType>();
    networkOperatorMap.put("44010", DOCOMO);
    networkOperatorMap.put("44020", SOFTBANK);
    networkOperatorMap.put("44070", KDDI);
    NETWORK_OPERATOR_MAP = Collections.unmodifiableMap(networkOperatorMap);

    Set<String> nameSet = new HashSet<String>();
    for (EmojiProviderType emojiProviderType : values()) {
      nameSet.add(emojiProviderType.name());
    }
    NAME_SET = Collections.unmodifiableSet(nameSet);
  }

  private EmojiProviderType(byte bitMask) {
    this.bitMask = bitMask;
  }

  public byte getBitMask() {
    return bitMask;
  }

  /**
   * @return EmojiProviderType, including NONE. NONE if the detection fails.
   */
  public static EmojiProviderType detectEmojiProviderTypeByMobileNetworkOperator(
      TelephonyManagerInterface telephonyManager) {
    Preconditions.checkNotNull(telephonyManager);

    // TODO(hsumita): Consider to make the default value UNICODE.
    return MoreObjects.firstNonNull(NETWORK_OPERATOR_MAP.get(telephonyManager.getNetworkOperator()),
                                NONE);
  }
}
