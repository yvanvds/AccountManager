using Newtonsoft.Json.Linq;
using System;
using System.Collections.Generic;
using System.DirectoryServices;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountApi.Directory
{
    public class Account
    {
        public Account(DirectoryEntry entry)
        {
            uid = entry.Properties.Contains("sAMAccountName") ? entry.Properties["sAMAccountName"].Value.ToString() : "";
            firstName = entry.Properties.Contains("givenName") ? entry.Properties["givenName"].Value.ToString() : "";
            lastName = entry.Properties.Contains("sn") ? entry.Properties["sn"].Value.ToString() : "";
            fullName = entry.Properties.Contains("displayname") ? entry.Properties["displayname"].Value.ToString() : "";
            mailAlias = entry.Properties.Contains("smamailalias") ? entry.Properties["smamailalias"].Value.ToString() : "";
            wisaID = entry.Properties.Contains("smaWisaID") ? entry.Properties["smaWisaID"].Value.ToString() : "";
            wisaName = entry.Properties.Contains("smawisaname") ? entry.Properties["smawisaname"].Value.ToString() : "";
            classGroup = entry.Properties.Contains("smaClass") ? entry.Properties["smaClass"].Value.ToString() : "";
            state = entry.Properties.Contains("userAccountControl") ? (int)entry.Properties["userAccountControl"].Value : 0;
        }

        public Account(JObject obj)
        {
            uid = obj.ContainsKey("uid") ? obj["uid"].ToString() : "";
            firstName = obj.ContainsKey("firstName") ? obj["firstName"].ToString() : "";
            lastName = obj.ContainsKey("lastName") ? obj["lastName"].ToString() : "";
            fullName = obj.ContainsKey("fullName") ? obj["fullName"].ToString() : "";
            mailAlias = obj.ContainsKey("mailAlias") ? obj["mailAlias"].ToString() : "";
            wisaID = obj.ContainsKey("wisaID") ? obj["wisaID"].ToString() : "";
            wisaName = obj.ContainsKey("wisaName") ? obj["wisaName"].ToString() : "";
            classGroup = obj.ContainsKey("classGroup") ? obj["classGroup"].ToString() : "";
            state = obj.ContainsKey("state") ? Convert.ToInt32(obj["state"]) : 0;
        }

        public JObject ToJson()
        {
            var result = new JObject
            {
                ["uid"] = uid,
                ["firstName"] = firstName,
                ["lastName"] = lastName,
                ["fullName"] = fullName,
                ["mailAlais"] = mailAlias,
                ["wisaID"] = wisaID,
                ["wisaName"] = wisaName,
                ["classGroup"] = classGroup,
                ["state"] = state
            };
            return result;
        }

        private string uid;
        public string UID { get => uid; }

        private string firstName;
        public string FirstName { get => firstName; }

        private string lastName;
        public string LastName { get => lastName; }

        private string fullName;
        public string FullName { get => fullName; }

        private string mailAlias;
        public string MailAlias { get => mailAlias; }

        private string wisaID;
        public string WisaID { get => wisaID; }

        private string wisaName;
        public string WisaName { get => wisaName; }

        private string classGroup;
        public string ClassGroup { get => classGroup; }

        int state;
        internal int State
        {
            get => state;

            set
            {
                var entry = GetEntry(uid);
                entry.Properties["userAccountControl"].Value = value;
                entry.CommitChanges();
                entry.Close();
            }
        }

        public void Disable()
        {
            const int DISABLE_ACCOUNT = 0x0002;
            State |= DISABLE_ACCOUNT;
        }

        public void Enable()
        {
            const int DISABLE_ACCOUNT = 0x0002;
            State &= ~DISABLE_ACCOUNT;
        }

        public bool IsEnabled()
        {
            return (State & 0x0002) == 0;
        }

        public void Delete()
        {
            var entry = GetEntry(uid);
            var parent = entry.Parent;
            parent.Children.Remove(entry);
            parent.CommitChanges();
            entry.Close();
            parent.Close();
        }

        private static DirectoryEntry GetEntry(string uid)
        {
            return null;
        }
    }
}
