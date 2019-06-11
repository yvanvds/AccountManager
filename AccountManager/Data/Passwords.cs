using Newtonsoft.Json.Linq;
using System;
using System.Collections.Generic;
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
    }
}
