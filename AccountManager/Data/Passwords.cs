using MigraDoc.DocumentObjectModel;
using MigraDoc.Rendering;
using Newtonsoft.Json.Linq;
using PdfSharp.Pdf;
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager
{
    public sealed partial class Data
    {
        const string passwordFile = "Passwords.json";
        const string coPasswordFile = "CoPasswords.json";

        public List<Password> Passwords = new List<Password>();
        public List<CoPassword> CoPasswords = new List<CoPassword>();

        private void LoadPasswordFileContent()
        {
            Passwords.Clear();
            var location = Path.Combine(appFolder, passwordFile);
            if(File.Exists(location))
            {
                string content = File.ReadAllText(location);
                var newObj = JObject.Parse(content);
                if(newObj.ContainsKey("accounts"))
                {
                    var arr = newObj["accounts"].ToArray();
                    foreach(var item in arr)
                    {
                        Passwords.Add(new Password(item as JObject));
                    }
                }
            }

            CoPasswords.Clear();
            location = Path.Combine(appFolder, coPasswordFile);
            if (File.Exists(location))
            {
                string content = File.ReadAllText(location);
                var newObj = JObject.Parse(content);
                if (newObj.ContainsKey("accounts"))
                {
                    var arr = newObj["accounts"].ToArray();
                    foreach (var item in arr)
                    {
                        CoPasswords.Add(new CoPassword(item as JObject));
                    }
                }
            }
        }

        private void SavePasswordFileContent()
        {
            {
                var content = new JObject();
                var arr = new JArray();
                foreach (var pw in Passwords)
                {
                    arr.Add(pw.ToJson());
                }

                content["accounts"] = arr;

                var location = Path.Combine(appFolder, "Passwords.json");
                File.WriteAllText(location, content.ToString());
            }

            {
                var content = new JObject();
                var arr = new JArray();
                foreach (var pw in CoPasswords)
                {
                    arr.Add(pw.ToJson());
                }

                content["accounts"] = arr;

                var location = Path.Combine(appFolder, "CoPasswords.json");
                File.WriteAllText(location, content.ToString());
            }
        }

        public void SaveCoPasswords(string fileName)
        {
            List<string> content = new List<string>();

            content.Add(CoPassword.GetHeaders());
            foreach(var item in CoPasswords)
            {
                content.Add(item.GetAsCSV());
            }
            File.WriteAllLines(fileName, content);

            CoPasswords.Clear();
        }

        public async Task SavePasswordsToPdf(string fileName)
        {
            await Task.Run(() =>
            {
                var document = new Document();

                var titleStyle = document.Styles["Heading1"];
                titleStyle.Font.Name = "Tahoma";
                titleStyle.Font.Size = 16;
                titleStyle.Font.Bold = true;
                titleStyle.ParagraphFormat.SpaceAfter = 12;

                var normalStyle = document.Styles["Normal"];
                normalStyle.Font.Name = "Times New Roman";
                normalStyle.Font.Size = 12;
                normalStyle.ParagraphFormat.SpaceAfter = 6;

                var passwordStyle = document.Styles.AddStyle("PasswordStyle", "Normal");
                passwordStyle.Font.Name = "Courier New";
                passwordStyle.Font.Size = 10;
                passwordStyle.ParagraphFormat.SpaceBefore = 12;
                passwordStyle.ParagraphFormat.SpaceAfter = 12;

                foreach (var pw in Passwords)
                {
                    var section = document.AddSection();
                    section.AddParagraph("Account voor " + pw.Name + " - " + pw.ClassGroup, "Heading1");

                    var line1 = section.AddParagraph("Je gebruikersnaam is ", "Normal");
                    line1.AddFormattedText(pw.AccountName, TextFormat.Bold);
                    line1.AddFormattedText(". Hiermee kan je inloggen op de computers in de school, op smartschool en bij Office365. " +
                        "Je gebruikt daarbij het volgende wachtwoord:");

                    section.AddParagraph(pw.ADPassword, "PasswordStyle");

                    var line2 = section.AddParagraph("Om in te loggen op smartschool heb je een ander wachtwoord nodig:", "Normal");

                    section.AddParagraph(pw.SSPassword, "PasswordStyle");

                    var line3 = section.AddParagraph("Op smartschool moet je je wachtwoord aanpassen wanneer je voor het eerst inlogt. " +
                        "Je kan zo je wachtwoord gelijkstellen aan het eerste wachtwoord.",
                        "Normal");
                }

                var pdfRenderer = new PdfDocumentRenderer();
                pdfRenderer.Document = document;
                pdfRenderer.RenderDocument();

                try
                {
                    pdfRenderer.PdfDocument.Save(fileName);
                    Passwords.Clear();
                } catch(Exception)
                {
                    MainWindow.Instance.Log.AddError(AccountApi.Origin.Other, "Unable to save to file: " + fileName);
                }
                
                Process.Start(fileName);
            });
            
        }
    }
}
