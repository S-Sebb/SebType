//! Just enough protobuf for Mozc's config1.db and user_dictionary.db: top-level fields are read and
//! written as they are, so fields SebType doesn't know stay untouched.

pub struct Field<'a> {
    pub number: u32,
    pub varint: Option<u64>,
    pub bytes: &'a [u8], // the value of a length-delimited field
    pub whole: &'a [u8], // key and value, for copying the field as it is
}

fn read_varint(b: &[u8], i: &mut usize) -> Result<u64, String> {
    let (mut n, mut shift) = (0u64, 0);
    loop {
        let c = *b.get(*i).ok_or("protobuf ends inside a number")?;
        *i += 1;
        n |= u64::from(c & 0x7f) << shift;
        if c < 0x80 {
            return Ok(n);
        }
        shift += 7;
        if shift > 63 {
            return Err("protobuf number too long".into());
        }
    }
}

pub fn fields(b: &[u8]) -> Result<Vec<Field<'_>>, String> {
    let mut out = vec![];
    let mut i = 0;
    while i < b.len() {
        let start = i;
        let key = read_varint(b, &mut i)?;
        let (mut varint, mut bytes) = (None, &b[0..0]);
        match key & 7 {
            0 => varint = Some(read_varint(b, &mut i)?),
            1 => i += 8,
            2 => {
                let n = read_varint(b, &mut i)? as usize;
                bytes = b.get(i..i + n).ok_or("protobuf field runs past the end")?;
                i += n;
            }
            5 => i += 4,
            w => return Err(format!("unexpected protobuf wire type {w}")),
        }
        if i > b.len() {
            return Err("protobuf field runs past the end".into());
        }
        out.push(Field {
            number: (key >> 3) as u32,
            varint,
            bytes,
            whole: &b[start..i],
        });
    }
    Ok(out)
}

pub fn varint(mut n: u64) -> Vec<u8> {
    let mut out = vec![];
    loop {
        let c = (n & 0x7f) as u8;
        n >>= 7;
        if n == 0 {
            out.push(c);
            return out;
        }
        out.push(c | 0x80);
    }
}

pub fn varint_field(number: u32, n: u64) -> Vec<u8> {
    let mut out = varint(u64::from(number) << 3);
    out.extend(varint(n));
    out
}

pub fn bytes_field(number: u32, value: &[u8]) -> Vec<u8> {
    let mut out = varint(u64::from(number) << 3 | 2);
    out.extend(varint(value.len() as u64));
    out.extend_from_slice(value);
    out
}

pub fn get_varint(b: &[u8], number: u32) -> Result<Option<u64>, String> {
    Ok(fields(b)?
        .iter()
        .rev()
        .find(|f| f.number == number)
        .and_then(|f| f.varint))
}

/// `b` with field `number` set to `value` (or removed for None), in field-number order.
pub fn set_varint(b: &[u8], number: u32, value: Option<u64>) -> Result<Vec<u8>, String> {
    let mut out = vec![];
    let mut placed = value.is_none();
    for f in fields(b)? {
        if f.number == number {
            continue;
        }
        if !placed && f.number > number {
            out.extend(varint_field(number, value.unwrap()));
            placed = true;
        }
        out.extend_from_slice(f.whole);
    }
    if !placed {
        out.extend(varint_field(number, value.unwrap()));
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sets_a_field_in_order_and_keeps_the_others() {
        // field 41 = 0, field 42 = "ab", field 60 = 1
        let mut cfg = varint_field(41, 0);
        cfg.extend(bytes_field(42, b"ab"));
        cfg.extend(varint_field(60, 1));
        let set = set_varint(&cfg, 47, Some(2)).unwrap();
        let numbers: Vec<u32> = fields(&set).unwrap().iter().map(|f| f.number).collect();
        assert_eq!(numbers, [41, 42, 47, 60]);
        assert_eq!(get_varint(&set, 47).unwrap(), Some(2));
        assert_eq!(set_varint(&set, 47, None).unwrap(), cfg);
        assert_eq!(fields(&set).unwrap()[1].bytes, b"ab");
    }

    #[test]
    fn rejects_a_truncated_file() {
        assert!(fields(&[0x12, 0x05, b'a']).is_err());
    }
}
