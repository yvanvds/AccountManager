using AccountManager.State;
using MigraDoc.DocumentObjectModel;
using MigraDoc.Rendering;
using Newtonsoft.Json.Linq;
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.Exporters.Passwords
{
    public class Manager<T> where T: AbstractPassword
    {
        public List<T> List = new List<T>();

        string fileName;

        public Manager(string fileName)
        {
            this.fileName = fileName;
            load();
        }

        ~Manager()
        {
            save();
        }

        private void load()
        {
            List.Clear();
            var location = Path.Combine(State.App.GetAppFolder(), fileName);
            if (File.Exists(location))
            {
                string content = File.ReadAllText(location);
                var newObj = JObject.Parse(content);
                if (newObj.ContainsKey("accounts"))
                {
                    var arr = newObj["accounts"].ToArray();
                    foreach (var item in arr)
                    {
                       List.Add(createNew(item as JObject) as T);
                    }
                }
            }
        }

        private void save()
        {
            var content = new JObject();
            var arr = new JArray();
            foreach (var pw in List)
            {
                arr.Add(pw.ToJson());
            }

            content["accounts"] = arr;

            var location = Path.Combine(State.App.GetAppFolder(), fileName);
            File.WriteAllText(location, content.ToString());
        }

        private AbstractPassword createNew(JObject item)
        {
            if (typeof(T) == typeof(AccountPassword))
            {
                return new AccountPassword(item);
            } else if (typeof(T) == typeof(CoAccountPassword))
            {
                return new CoAccountPassword(item);
            }
            return null;
        }

        public async Task Export()
        {
            await Export(fileName).ConfigureAwait(false);
        }

        public async Task Export(string fileName)
        {

            if (typeof(T) == typeof(AccountPassword))
            {
                await exportToPDF(fileName).ConfigureAwait(false);
            }
            else if (typeof(T) == typeof(CoAccountPassword))
            {
                await exportToCSV(fileName).ConfigureAwait(false);
            }
        }

        private async Task exportToCSV(string fileName)
        {
            await Task.Run(() =>
            {
                List<string> content = new List<string>();

                content.Add("Gebruikersnaam;Naam;Klas;CoAccount1;CoAccount2;CoAccount3;CoAccount4;CoAccount5;CoAccount6");
                foreach (var item in List)
                {
                    content.Add((item as CoAccountPassword).GetCSV());
                }
                File.WriteAllLines(fileName, content);

                List.Clear();
            }).ConfigureAwait(false);
        }

        public async Task exportToPDF(string fileName)
        {
            await Task.Run(() =>
            {
                var document = createDocument();

                foreach (var password in List)
                {
                    var pw = password as AccountPassword;
                    var section = document.AddSection();
                    section.AddParagraph("Account voor " + pw.Name + " - " + pw.ClassGroup, "Heading1");

                    
                    section.AddParagraph("Login     : " + pw.AccountName, "PasswordStyle");

                    if (pw.AzurePassword.Length > 0)
                    {
                        section.AddParagraph("Office365", "Heading2");
                        section.AddParagraph("Je beschikt ook over een Office365 account waarmee je kan inloggen op https://www.office.com/ en je laptop, indien aangekocht via de school. Je kan dit e-mail adres gebruiken, maar de " +
                            "communicatie met de school en je leerkrachten verloopts steeds via smartschool. Je kan wel alle Office365 programma's zoals Word en "
                            + "Powerpoint online gebruiken of installeren op een computer naar keuze.", "Normal");
                        section.AddParagraph("Login     : " + pw.Mail, "PasswordStyle");
                        section.AddParagraph("Wachtwoord: " + pw.AzurePassword, "PasswordStyle");
                        section.AddParagraph("Dit wachtwoord is eenmalig. Wanneer je inlogt, zal je een nieuw wachtwoord moeten te kiezen.", "Normal");
                    }

                    if (pw.SSPassword.Length > 0)
                    {
                        section.AddParagraph("Smartschool", "Heading2");
                        section.AddParagraph("Je gebruikt de website https://sanctamaria-aarschot.smartschool.be", "Normal");
                        section.AddParagraph("Als je de smartphone app gebruikt, zorg er dan voor dat je de juiste school kiest (sanctamaria-aarschot)!", "Normal");
                        section.AddParagraph("Je kan inloggen bij smartschool met deze login, en het volgende wachtwoord:", "Normal");
                        section.AddParagraph("Login     : " + pw.AccountName, "PasswordStyle");
                        section.AddParagraph(pw.SSPassword, "PasswordStyle");
                        section.AddParagraph("Dit wachtwoord is eenmalig. Wanneer je inlogt, zal je een nieuw wachtwoord moeten te kiezen.", "Normal");

                    }

                    section.AddParagraph("WiFi", "Heading2");
                    section.AddParagraph("Met deze gegevens kan je inloggen op het Smifi-L wifi netwerk.", "Normal");
                    section.AddParagraph("Wachtwoord: SmifiDeWifi:)", "PasswordStyle");

                    
                    section.AddParagraph("Privacy", "Heading2");
                    section.AddParagraph("Je account is strikt persoonlijk. Indien je je account doorgeeft aan anderen, dan ben jij " +
                        "verantwoordelijk voor hun acties op het netwerk. Laat dit blad dus niet rondslingeren maar leer je login " +
                        "en wachtwoord vanbuiten. Zou je je wachtwoord vergeten, dan kan je een nieuw wachtwoord krijgen op Secretariaat 1.", "Normal");
                    section.AddParagraph("Geef nooit (NOOIT!) je wachtwoord door, ook niet aan leerkrachten.");
                }

                var pdfRenderer = new PdfDocumentRenderer();
                pdfRenderer.Document = document;
                pdfRenderer.RenderDocument();

                try
                {
                    pdfRenderer.PdfDocument.Save(fileName);
                    List.Clear();
                }
                catch (Exception)
                {
                    MainWindow.Instance.Log.AddError(AccountApi.Origin.Other, "Unable to save to file: " + fileName);
                }

                Process.Start(fileName);
            }).ConfigureAwait(false);

            
        }

        public async Task ExportStaffPasswordToPDF(string name, string username, string mail, string smartschoolPassword = null, string office365Password = null)
        {
            await Task.Run(() =>
            {
                var document = createDocument();

                var section = document.AddSection();
                section.AddParagraph("Account voor " + name, "Heading1");

                if (office365Password != null)
                {
                    section.AddParagraph("Office365", "Heading2");
                    section.AddParagraph("Login     : " + mail, "PasswordStyle");
                    section.AddParagraph("Wachtwoord: " + office365Password, "PasswordStyle");
                    section.AddParagraph("Wanneer je inlogt, kan je een nieuw wachtwoord kiezen.", "Normal");
                }


                    section.AddParagraph("Wifi", "Heading2");
                    section.AddParagraph("Code: !TEAM!SMA!", "PasswordStyle");

                    section.AddParagraph("Met deze gegevens kan je inloggen op het Smifi-P wifi netwerk.", "Normal");


                if (smartschoolPassword != null)
                {
                    section.AddParagraph("Smartschool", "Heading2");
                    section.AddParagraph("Je gebruikt de website https://sanctamaria-aarschot.smartschool.be", "Normal");
                    section.AddParagraph("Login     : " + username, "PasswordStyle");
                    section.AddParagraph("Wachtwoord: " + smartschoolPassword, "PasswordStyle");
                    section.AddParagraph("Wanneer je inlogt, kan je een nieuw wachtwoord kiezen.", "Normal");

                }

                section.AddParagraph("Privacy", "Heading2");
                section.AddParagraph("Je account is strikt persoonlijk. Indien je je account doorgeeft aan anderen, dan ben jij " +
                    "verantwoordelijk voor hun acties op het netwerk. Laat dit blad dus niet rondslingeren maar leer je login " +
                    "en wachtwoord vanbuiten. Zou je je wachtwoord vergeten, dan kan je een nieuw wachtwoord krijgen op Secretariaat 1.", "Normal");
                section.AddParagraph("Geef nooit (NOOIT!) je wachtwoord door, ook niet aan collegas.");


                var pdfRenderer = new PdfDocumentRenderer();
                pdfRenderer.Document = document;
                pdfRenderer.RenderDocument();




                string fileName = name + ".pdf";
                fileName = Path.GetTempPath() + fileName;
                try
                {
                    pdfRenderer.PdfDocument.Save(fileName);
                    List.Clear();
                }
                catch (Exception)
                {
                    MainWindow.Instance.Log.AddError(AccountApi.Origin.Other, "Unable to save to file: " + fileName);
                }

                Process.Start(fileName);
            }).ConfigureAwait(false);


        }

        Document createDocument()
        {
            var document = new Document();

            var titleStyle = document.Styles["Heading1"];
            titleStyle.Font.Name = "Tahoma";
            titleStyle.Font.Size = 16;
            titleStyle.Font.Bold = true;
            titleStyle.ParagraphFormat.SpaceAfter = 12;
            var border = new Border();
            border.Width = "1pt";
            border.Color = Colors.Black;
            titleStyle.ParagraphFormat.Borders.Bottom = border;

            var subTitleStyle = document.Styles["Heading2"];
            subTitleStyle.Font.Name = "Tahoma";
            subTitleStyle.Font.Size = 14;
            subTitleStyle.Font.Bold = true;
            subTitleStyle.ParagraphFormat.SpaceAfter = 10;
            var zeroborder = new Border();
            zeroborder.Width = "0pt";
            zeroborder.Color = Colors.White;
            subTitleStyle.ParagraphFormat.Borders.Bottom = zeroborder;

            var normalStyle = document.Styles["Normal"];
            normalStyle.Font.Name = "Times New Roman";
            normalStyle.Font.Size = 12;
            normalStyle.ParagraphFormat.SpaceAfter = 6;

            var passwordStyle = document.Styles.AddStyle("PasswordStyle", "Normal");
            passwordStyle.Font.Name = "Courier New";
            passwordStyle.Font.Size = 10;
            passwordStyle.ParagraphFormat.SpaceBefore = 12;
            passwordStyle.ParagraphFormat.SpaceAfter = 12;

            return document;
        }
    }
}
