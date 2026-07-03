// MAXX Events — Quotes Sheet API
// ------------------------------------------------
// HOW TO REDEPLOY (this sheet already exists — you're just updating its script):
// 1. Open your "Quotes" Google Sheet → Extensions → Apps Script
// 2. Select all existing code, delete it, and paste this entire file
// 3. Click Save (the disk icon)
// 4. Deploy → Manage deployments → click the pencil (edit) icon on the
//    existing deployment
//    - Version: New version
//    - Execute as: Me
//    - Who has access: Anyone
// 5. Click Deploy
//    (The Web App URL stays exactly the same, so nothing needs to change
//    in booking_form/index.html, bookers-details.html or manual-entry.html)
// ------------------------------------------------

const SHEET_NAME = "Quotes";

const HEADERS = [
  "Timestamp", "Name", "Phone", "Person Name", "Event Type",
  "Event Date", "Location", "Budget", "Venue Type", "Venue Name",
  "Services Count", "Non-Veg Count", "Veg Count", "Notes",
  "Quote Code", "Status", "Source", "Services"
];

function getSheet_() {
  const ss = SpreadsheetApp.getActiveSpreadsheet();
  let sheet = ss.getSheetByName(SHEET_NAME);

  if (!sheet) {
    sheet = ss.insertSheet(SHEET_NAME);
  }

  if (sheet.getLastRow() === 0) {
    sheet.appendRow(HEADERS);
    sheet.getRange(1, 1, 1, HEADERS.length)
      .setBackground("#0d1b4b")
      .setFontColor("#C9A84C")
      .setFontWeight("bold");
    sheet.setFrozenRows(1);
  } else {
    const existingHeaders = sheet.getRange(1, 1, 1, sheet.getLastColumn()).getValues()[0];
    if (existingHeaders.length < HEADERS.length) {
      sheet.getRange(1, existingHeaders.length + 1, 1, HEADERS.length - existingHeaders.length)
        .setValues([HEADERS.slice(existingHeaders.length)]);
    }
  }

  return sheet;
}

function jsonOut_(obj) {
  return ContentService
    .createTextOutput(JSON.stringify(obj))
    .setMimeType(ContentService.MimeType.JSON);
}

function formatServicesCell_(servicesObj) {
  if (!servicesObj) return "";
  if (typeof servicesObj === "string") {
    if (servicesObj.trim().startsWith("{")) {
      try { return formatServicesCell_(JSON.parse(servicesObj)); } catch (e) {}
    }
    return servicesObj;
  }
  const lines = [];
  Object.keys(servicesObj).forEach(function(cat) {
    const items = servicesObj[cat];
    if (items && items.length) lines.push(cat + " | " + items.join("; "));
  });
  return lines.join("\n");
}

function parseServicesCell_(val) {
  if (!val) return {};
  const s = String(val);
  if (s.trim().startsWith("{")) {
    try { return JSON.parse(s); } catch (e) {}
  }
  const services = {};
  s.split("\n").forEach(function(line) {
    const idx = line.indexOf("|");
    if (idx === -1) return;
    const cat = line.slice(0, idx).trim();
    const items = line.slice(idx + 1).split(";").map(function(x) { return x.trim(); }).filter(Boolean);
    if (cat && items.length) services[cat] = items;
  });
  return services;
}

function rowToBooker_(row, sheetRowNum, sheet) {
  if (!row.some(function(cell) { return cell !== "" && cell !== null; })) return null;

  if (!row[14]) {
    const code = "MX-LEGACY-" + sheetRowNum;
    sheet.getRange(sheetRowNum, 15).setValue(code);
    row[14] = code;
  }

  return {
    submittedAt: row[0] ? String(row[0]) : "",
    name: row[1] ? String(row[1]) : "",
    phone: row[2] ? String(row[2]) : "",
    personName: row[3] ? String(row[3]) : "",
    eventType: row[4] ? String(row[4]) : "",
    date: row[5] ? String(row[5]) : "",
    location: row[6] ? String(row[6]) : "",
    budget: row[7] ? String(row[7]) : "",
    venueType: row[8] ? String(row[8]) : "",
    venueNote: row[9] ? String(row[9]) : "",
    servicesCount: row[10] || 0,
    nonVegCount: row[11] ? String(row[11]) : "",
    vegCount: row[12] ? String(row[12]) : "",
    notes: row[13] ? String(row[13]) : "",
    quoteCode: row[14] ? String(row[14]) : "",
    status: row[15] ? String(row[15]) : "New",
    source: row[16] ? String(row[16]) : "form",
    services: parseServicesCell_(row[17])
  };
}

function findRowByQuoteCode_(sheet, quoteCode) {
  const lastRow = sheet.getLastRow();
  if (lastRow < 2 || !quoteCode) return -1;
  const codes = sheet.getRange(2, 15, lastRow - 1, 1).getValues();
  for (let i = 0; i < codes.length; i++) {
    if (String(codes[i][0]) === String(quoteCode)) return i + 2;
  }
  return -1;
}

function dataToRow_(data, isNew) {
  return [
    isNew ? new Date().toLocaleString("en-IN", { timeZone: "Asia/Kolkata" }) : data.timestamp || new Date().toLocaleString("en-IN", { timeZone: "Asia/Kolkata" }),
    data.name || "",
    data.phone || "",
    data.personName || "",
    data.eventType || "",
    data.date || "",
    data.location || "",
    data.budget || "",
    data.venueType || "",
    data.venueName || "",
    data.servicesCount || 0,
    data.nonVegCount || "",
    data.vegCount || "",
    data.notes || "",
    data.quoteCode || "",
    data.status || "New",
    data.source || "form",
    formatServicesCell_(data.services || "")
  ];
}

function doGet(e) {
  try {
    const sheet = getSheet_();
    const lastRow = sheet.getLastRow();
    if (lastRow < 2) return jsonOut_({ success: true, bookers: [] });

    const numRows = lastRow - 1;
    const values = sheet.getRange(2, 1, numRows, HEADERS.length).getValues();
    const bookers = [];

    values.forEach(function(row, i) {
      const booker = rowToBooker_(row, i + 2, sheet);
      if (booker) bookers.push(booker);
    });

    return jsonOut_({ success: true, bookers: bookers });
  } catch (err) {
    return jsonOut_({ success: false, error: err.toString() });
  }
}

function doPost(e) {
  try {
    const data = JSON.parse(e.postData.contents);
    const sheet = getSheet_();

    if (data.action === "updateStatus") {
      return updateStatus_(sheet, data.quoteCode, data.status);
    }

    if (data.action === "deleteDuplicates") {
      return deleteDuplicates_(sheet);
    }

    if (!data.name && !data.phone && !data.quoteCode) {
      return jsonOut_({ success: false, error: "Missing required fields" });
    }

    const existingRow = data.quoteCode ? findRowByQuoteCode_(sheet, data.quoteCode) : -1;

    if (existingRow > 0) {
      const existing = sheet.getRange(existingRow, 1, 1, HEADERS.length).getValues()[0];
      data.timestamp = existing[0];
      if (!data.status && existing[15]) data.status = existing[15];
      sheet.getRange(existingRow, 1, 1, HEADERS.length).setValues([dataToRow_(data, false)]);
      return jsonOut_({ success: true, code: data.quoteCode, updated: true });
    }

    sheet.appendRow(dataToRow_(data, true));
    return jsonOut_({ success: true, code: data.quoteCode });
  } catch (err) {
    return jsonOut_({ success: false, error: err.toString() });
  }
}

function updateStatus_(sheet, quoteCode, status) {
  const rowNum = findRowByQuoteCode_(sheet, quoteCode);
  if (rowNum < 0) return jsonOut_({ success: false, error: "Quote code not found" });
  sheet.getRange(rowNum, 16).setValue(status);
  return jsonOut_({ success: true });
}

function duplicateKey_(row) {
  const code = row[14] ? String(row[14]).trim() : "";
  if (code && !code.startsWith("MX-LEGACY-")) return "code:" + code;
  const phone = row[2] ? String(row[2]).replace(/\D/g, "").slice(-10) : "";
  const name = row[1] ? String(row[1]).toLowerCase().trim() : "";
  if (phone && name) return "phone:" + phone + "|" + name;
  return "";
}

function deleteDuplicates_(sheet) {
  const lastRow = sheet.getLastRow();
  if (lastRow < 2) return jsonOut_({ success: true, deleted: 0, kept: 0 });

  const values = sheet.getRange(2, 1, lastRow - 1, HEADERS.length).getValues();
  const keepIndex = {};

  values.forEach(function(row, i) {
    const key = duplicateKey_(row);
    if (!key) return;
    if (keepIndex[key] === undefined || new Date(row[0]) > new Date(values[keepIndex[key]][0])) {
      keepIndex[key] = i;
    }
  });

  const toDelete = [];
  values.forEach(function(row, i) {
    const key = duplicateKey_(row);
    if (key && keepIndex[key] !== i) toDelete.push(i + 2);
  });

  toDelete.sort(function(a, b) { return b - a; }).forEach(function(r) {
    sheet.deleteRow(r);
  });

  return jsonOut_({ success: true, deleted: toDelete.length, kept: Object.keys(keepIndex).length });
}

// Status options: New → Contacted → Quoted → Confirmed → Cancelled
