using Newtonsoft.Json.Linq;
using System;
using System.Collections.Generic;
using System.DirectoryServices;
using System.IO;
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
            gender = entry.Properties.Contains("smaGender") ? entry.Properties["smaGender"].Value.ToString() : "not set";
            copyCode = entry.Properties.Contains("employeeID") ? Convert.ToInt32(entry.Properties["employeeID"].Value) : 0;
            state = entry.Properties.Contains("userAccountControl") ? (int)entry.Properties["userAccountControl"].Value : 0;
            role = Connector.GetRoleFromPath(entry.Path);
            cn = entry.Properties.Contains("cn") ? entry.Properties["cn"].Value.ToString() : "";
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
            gender = obj.ContainsKey("gender") ? obj["gender"].ToString() : "not set";
            state = obj.ContainsKey("state") ? Convert.ToInt32(obj["state"]) : 0;
            copyCode = obj.ContainsKey("copyCode") ? Convert.ToInt32(obj["copyCode"]) : 0;
            string sRole = obj.ContainsKey("role") ? obj["role"].ToString() : "";
            switch(sRole)
            {
                case "Teacher": role = AccountRole.Teacher; break;
                case "Director": role = AccountRole.Director; break;
                case "Support": role = AccountRole.Support; break;
                case "IT": role = AccountRole.IT; break;
                default: role = AccountRole.Other; break;
            } 
            cn = obj.ContainsKey("cn") ? obj["cn"].ToString() : "";
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
                ["state"] = state,
                ["copyCode"] = copyCode,
                ["gender"] = gender,
                ["role"] = role.ToString(),
                ["cn"] = CN,
            };
            return result;
        }

        private string uid;
        public string UID { get => uid; }

        private string firstName;
        public string FirstName
        {
            get => firstName;
            set
            {
                var entry = GetEntry(uid);
                firstName = value;
                fullName = firstName + " " + LastName;
                entry.Properties["givenName"].Value = firstName;
                entry.Properties["displayname"].Value = fullName;
                entry.CommitChanges();
                entry.Close();
            }
        }

        private string lastName;
        public string LastName
        {
            get => lastName;
            set
            {
                var entry = GetEntry(uid);
                lastName = value;
                fullName = firstName + " " + LastName;
                entry.Properties["sn"].Value = lastName;
                entry.Properties["displayname"].Value = fullName;
                entry.CommitChanges();
                entry.Close();
            }
        }

        private string fullName;
        public string FullName { get => fullName; }

        private string gender;
        public string Gender
        {
            get => gender;
            set
            {
                var entry = GetEntry(uid);
                gender = value;
                entry.Properties["smaGender"].Value = gender;
                entry.CommitChanges();
                entry.Close();
            }
        }

        private string cn;
        public string CN {
            get => cn;
            set
            {
                cn = value;
                try
                {
                    var entry = GetEntry(uid);
                    entry.Rename("CN=" + cn);
                    entry.CommitChanges();
                    entry.Close();
                }
                catch (Exception) { }
                
            }
        }

        private string mailAlias;
        public string MailAlias { get => mailAlias; }

        private string wisaID;
        public string WisaID { get => wisaID; }

        private string wisaName;
        public string WisaName { get => wisaName; }

        private string classGroup;
        public string ClassGroup { get => classGroup; }

        private int copyCode;
        public int CopyCode {
            get => copyCode;
            set
            {
                var entry = GetEntry(uid);
                copyCode = value;
                entry.Properties["employeeID"].Value = copyCode.ToString();
                entry.CommitChanges();
                entry.Close();
            }
        }



        int state;
        internal int State
        {
            get => state;

            set
            {
                var entry = GetEntry(uid);
                state = value;
                entry.Properties["userAccountControl"].Value = value;
                entry.CommitChanges();
                entry.Close();
            }
        }

        AccountRole role;
        public AccountRole Role
        {
            get => role;
            set
            {
                if(value != AccountRole.Student)
                {
                    // never change a student to something else
                    var entry = GetEntry(UID);
                    role = value;
                    string path = Connector.GetPath(role);
                    var parent = Connector.GetEntry(path);
                    entry.MoveTo(parent);
                    entry.CommitChanges();
                    entry.Close();
                }
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
            if(entry != null)
            {
                string home = string.Empty ;
                if (entry.Properties["HomeDirectory"] != null)
                {
                    if (entry.Properties["HomeDirectory"].Value != null)
                        home = entry.Properties["HomeDirectory"].Value.ToString();
                }
                if(home != string.Empty)
                {
                    try
                    {
                        var dir = new DirectoryInfo(home);
                        dir.Delete(true);
                    } catch(Exception e)
                    {
                        Connector.Log.AddError(Origin.Directory, e.Message);
                    }
                    
                }
                var parent = entry.Parent;
                if (parent != null)
                {
                    parent.Children.Remove(entry);
                    parent.CommitChanges();
                    parent.Close();
                }
                entry.Close();
            }
            
        }

        public void SetPassword(string password)
        {
            var entry = GetEntry(uid);
            try
            {
                entry.Password = password;
                entry.CommitChanges();
            }
            catch(Exception e)
            {
                Connector.Log.AddError(Origin.Directory, e.Message);
            }
        }

        public void MoveToClassGroup(DirectoryEntry newParent, string ClassGroup)
        {
            var entry = GetEntry(UID);
            classGroup = ClassGroup;
            entry.Properties["smaClass"].Value = ClassGroup;
            entry.CommitChanges();
            entry.MoveTo(newParent);
            entry.CommitChanges();
            entry.Close();
        }

        private static DirectoryEntry GetEntry(string uid)
        {
            return Connector.GetEntryByUID(uid);
        }

        public string DesiredCN()
        {
            return fullName + " (" + uid + ")";
        }
    }
}
