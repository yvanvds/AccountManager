using Newtonsoft.Json;
using Newtonsoft.Json.Linq;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountApi.Smartschool
{
    /// <summary>
    /// A Smartschool account group. Groups can have have Child groups, Accounts and group properties.
    /// </summary>
    public class Group : IGroup
    {
        /// <summary>
        /// Creates a Smartschool group. Parent can be null if this is the main group.
        /// </summary>
        /// <param name="parent">The Parent group. Can be null.</param>
        public Group(IGroup parent)
        {
            this.Parent = parent;
        }

        string name = string.Empty;
        /// <summary>
        /// The Name of the group
        /// </summary>
        public string Name { get => name; set => name = value; }

        string description = string.Empty;
        /// <summary>
        /// The group description
        /// </summary>
        public string Description { get => description; set => description = value; }

        GroupType type = GroupType.Invalid;
        /// <summary>
        /// The group type. Can be Group, Class or Invalid.
        /// </summary>
        public GroupType Type { get => type; set => type = value; }

        string code = string.Empty;
        public string Code { get => code; set => code = value; }

        string untis = string.Empty;
        /// <summary>
        /// Untis code is used to link class schedules
        /// </summary>
        public string Untis { get => untis; set => untis = value; }

        bool visible = false;
        /// <summary>
        /// If the group is visible for normal users.
        /// </summary>
        public bool Visible { get => visible; set => visible = value; }

        bool official = false;
        /// <summary>
        /// Wether or not this group is an official group. Official groups are classes with students.
        /// Official groups need to have an AdminNumber and InstituteNumber.
        /// </summary>
        public bool Official { get => official; set => official = value; }

        string coAccountLabel = string.Empty;
        /// <summary>
        /// The name co-accounts will see for this group. This value is optional.
        /// </summary>
        public string CoAccountLabel { get => coAccountLabel; set => coAccountLabel = value; }

        int adminNumber = 0;
        /// <summary>
        ///  Administative numbers are also present in Wisa. Every study domain has its own number
        ///  and must be added to official groups.
        /// </summary>
        public int AdminNumber { get => adminNumber; set => adminNumber = value; }

        string instituteNumber = string.Empty;
        /// <summary>
        /// Institute Number. Must be added for official groups. It's a normal numeric value, but the
        /// code must exist in smartschool. If not, the entry will be rejected.
        /// </summary>
        public string InstituteNumber { get => instituteNumber; set => instituteNumber = value; }

        List<string> titulars;
        /// <summary>
        /// The (co-)titulars in a list of strings. Because of limitations by smartschool this field cannot
        /// be saved right now.
        /// </summary>
        public List<string> Titulars { get => titulars; set => titulars = value; }

        List<IGroup> children;
        /// <summary>
        /// The child groups in this group.
        /// </summary>
        public List<IGroup> Children { get => children; set => children = value; }

        List<IAccount> accounts = new List<IAccount>();
        /// <summary>
        /// The accounts in this group.
        /// </summary>
        public List<IAccount> Accounts { get => accounts; set => accounts = value; }

        /// <summary>
        /// The parent group. Groups at level 0 have no parent and this will return null.
        /// </summary>
        public IGroup Parent { get; set; } = null;

        /// <summary>
        /// Find a group by its name. Subgroups will also be searched, unless this group is added
        /// to the list with discarded subgroups in the Connector.
        /// </summary>
        /// <param name="name">The group name to find.</param>
        /// <returns>The group with this name, or null if not found.</returns>
        public IGroup Find(string name)
        {
            if (Name.Equals(name)) return this;

            if (children == null) return null;

            if (Connector.DiscardSubgroups.Contains(Name)) return null;

            foreach (var group in children)
            {

                var result = group.Find(name);
                if (result != null) return result;
            }
            return null;
        }

        public bool HasParent(string name)
        {
            if (Parent == null) return false;
            if (Parent.Name == name) return true;
            return Parent.HasParent(name);
        }

        /// <summary>
        /// Get the number of official groups (Classes) within this group. If this group is in the 
        /// list with DiscardedSubgroups, subgroups will not be evaluated.
        /// </summary>
        public int CountClassGroupsOnly
        {
            get
            {
                int count = 0;
                if (Connector.DiscardSubgroups.Contains(Name)) return count;

                if (children != null) foreach (var group in children)
                    {
                        count += group.CountClassGroupsOnly;
                    }
                if (Official)
                {
                    count++;
                }

                return count;
            }
        }

        /// <summary>
        /// Get the number of groups (Classes) within this group. If this group is in the 
        /// list with DiscardedSubgroups, subgroups will not be evaluated.
        /// </summary>
        public int Count
        {
            get
            {
                int count = 0;
                if (Connector.DiscardSubgroups.Contains(Name)) return count;

                if (children != null) foreach (var group in children)
                    {
                        count += group.Count;
                    }
                count++;


                return count;
            }
        }

        /// <summary>
        /// Counts the number of accounts in this group and all its subgroups. If this group is present
        /// in the list Connector.DiscardSubgroups, the child groups will not be evaluated.
        /// </summary>
        /// <returns>The number of subgroups</returns>
        public int NumAccounts()
        {
            int count = 0;
            if (Connector.DiscardSubgroups.Contains(Name)) return count;

            if (children != null)
            {
                foreach (var group in children)
                {
                    try
                    {
                        count += group.NumAccounts();
                    }
                    catch (Exception e)
                    {
                        Connector.Log.AddError(Origin.Smartschool, "Group Error: " + e.Message + "in group " + group.Name);
                    }
                }
            }
            if (Accounts != null)
            {
                count += Accounts.Count;
            }

            return count;
        }

        /// <summary>
        /// Sort all child groups by name. This is a recursive method.
        /// </summary>
        public void Sort()
        {
            if (children == null) return;
            children.Sort((x, y) => x.Name.CompareTo(y.Name));
            foreach (var child in children)
            {
                child.Sort();
            }
            if (accounts != null) accounts.Sort((x, y) => x.SurName.CompareTo(y.SurName));
        }

        /// <summary>
        /// Get all child groups as a list. This is a recursive method.
        /// </summary>
        /// <param name="list"></param>
        public void GetTreeAsList(List<IGroup> list)
        {

            if (children != null && !Connector.DiscardSubgroups.Contains(Name))
            {
                foreach (var child in children)
                {
                    child.GetTreeAsList(list);
                }
            }

            list.Add(this);
        }

        /// <summary>
        /// Loads the accounts in this group from smartschool. This method is NOT recursive.
        /// </summary>
        /// <returns></returns>
        public async Task LoadAccounts()
        {
            var jsonResult = await Task.Run(
             () => Connector.service.getAllAccountsExtended(Connector.password, Name, "0")
            );

            if (jsonResult is int)
            {
                // probably just a group without direct accounts
                if ((int)jsonResult == 19)
                {
                    return;
                }
                else
                {
                    Error.AddError((int)jsonResult);
                    return;
                }
            }

            try
            {
                List<JSONAccount> details = JsonConvert.DeserializeObject<List<JSONAccount>>(jsonResult.ToString());

                Accounts.Clear();
                foreach (var account in details)
                {
                    Accounts.Add(new Account());
                    Accounts.Last().Group = Name;

                    AccountManager.LoadFromJSON(Accounts.Last(), account);
                }

                Error.AddMessage("Added " + Accounts.Count.ToString() + " Accounts to " + Name);
            }
            catch (Exception e)
            {
                Error.AddError(e.Message);
            }
        }

        public void ApplyImportRules(List<IRule> rules)
        {
            if (Children == null) return;
            for (int i = Children.Count - 1; i >= 0; i--)
            {
                Children[i].ApplyImportRules(rules);

                for (int j = 0; j < rules.Count; j++)
                {
                    if (rules[j].ShouldApply(Children[i]))
                    {
                        if (rules[j].RuleAction == RuleAction.Discard)
                        {
                            Children.Remove(Children[i]);
                            break;
                        }
                    }
                }
            }
        }

        /// <summary>
        /// Create a JSON JObject from this group.
        /// </summary>
        /// <returns>The new JObject</returns>
        public JObject ToJson(bool includeAccounts)
        {
            JObject result = new JObject
            {
                ["Name"] = Name,
                ["Description"] = Description,
                ["Code"] = Code,
                ["Official"] = Official,
                ["Visible"] = Visible,
                ["Type"] = Type.ToString(),
                ["Untis"] = Untis,
                ["InstituteNumber"] = InstituteNumber,
                ["AdminNumber"] = AdminNumber
            };

            if (includeAccounts && Accounts != null)
            {
                var accounts = new JArray();
                foreach (var account in Accounts)
                {
                    accounts.Add(account.ToJson());
                }
                result["Accounts"] = accounts;
            }

            if (Children != null)
            {
                var children = new JArray();
                foreach (var child in Children)
                {
                    children.Add(child.ToJson(includeAccounts));
                }
                result["Children"] = children;
            }

            return result;
        }

        /// <summary>
        /// Create a group from a JSON object.
        /// </summary>
        /// <param name="parent">The parent of this group in the tree model.</param>
        /// <param name="obj">The JObject to retrieve data from.</param>
        public Group(IGroup parent, JObject obj)
        {
            Parent = parent;
            Name = obj["Name"].ToString();
            Description = obj["Description"].ToString();
            Code = obj["Code"].ToString();
            Official = (bool)obj["Official"];
            Visible = (bool)obj["Visible"];
            string groupType = obj["Type"].ToString();
            switch (groupType)
            {
                case "Group": Type = GroupType.Group; break;
                case "Class": Type = GroupType.Class; break;
                default: Type = GroupType.Invalid; break;
            }
            Untis = obj["Untis"].ToString();
            InstituteNumber = obj["InstituteNumber"].ToString();
            AdminNumber = Convert.ToInt32(obj["AdminNumber"]);

            if (obj.ContainsKey("Accounts"))
            {
                Accounts = new List<IAccount>();
                var arr = obj["Accounts"].ToArray();
                foreach (var account in arr)
                {
                    Accounts.Add(new Account(account as JObject));
                }
            }

            if (obj.ContainsKey("Children"))
            {
                Children = new List<IGroup>();
                var arr = obj["Children"].ToArray();
                foreach (var group in arr)
                {
                    Children.Add(new Group(this, group as JObject));
                }
            }
        }

        /// <summary>
        /// Check if this group is equal to another group.
        /// </summary>
        /// <param name="other">The Other group</param>
        /// <param name="recursive">Also check child groups</param>
        /// <returns>True if equal.</returns>
        public bool Equals(IGroup other, bool recursive, bool includeAccounts)
        {
            if (!Name.Equals(other.Name))
            {
                Error.AddMessage("Group Name is different: " + Name + " other: " + other.Name);
                return false;
            }
            if (!Description.Equals(other.Description))
            {
                Error.AddMessage("Group " + Name + " Description is different: " + Description + " other: " + other.Description);
                return false;
            }
            if (!Code.Equals(other.Code))
            {
                Error.AddMessage("Group " + Name + " Code is different: " + Code + " other: " + other.Code);
                return false;
            }
            if (!Official.Equals(other.Official))
            {
                Error.AddMessage("Group " + Name + " Official is different: " + Official + " other: " + other.Official);
                return false;
            }
            if (!Visible.Equals(other.Visible))
            {
                Error.AddMessage("Group " + Name + " Visible is different: " + Visible + " other: " + other.Visible);
                return false;
            }
            if (!Type.Equals(other.Type))
            {
                Error.AddMessage("Group " + Name + " Type is different: " + Type + " other: " + other.Type);
                return false;
            }
            if (!Untis.Equals(other.Untis))
            {
                Error.AddMessage("Group " + Name + " Untis is different: " + Untis + " other: " + other.Untis);
                return false;
            }
            if (!InstituteNumber.Equals(other.InstituteNumber))
            {
                Error.AddMessage("Group " + Name + " Institute is different: " + InstituteNumber + " other: " + other.InstituteNumber);
                return false;
            }
            if (!AdminNumber.Equals(other.AdminNumber))
            {
                Error.AddMessage("Group " + Name + " AdminNumber is different: " + AdminNumber + " other: " + other.AdminNumber);
                return false;
            }

            if (includeAccounts)
            {
                if (Accounts == null && other.Accounts != null)
                {
                    Error.AddMessage("Group " + Name + " Accounts is null");
                    return false;
                }

                if (Accounts != null && other.Accounts == null)
                {
                    Error.AddMessage("Group " + Name + " other accounts is null");
                    return false;
                }

                if (Accounts != null && other.Accounts != null)
                {
                    if (Accounts.Count != other.Accounts.Count)
                    {
                        Error.AddMessage("Group " + Name + " has " + Accounts.Count + " accounts and other has " + other.Accounts.Count);
                        return false;
                    }

                    for (int i = 0; i < Accounts.Count; i++)
                    {
                        if (!Accounts[i].Equals(other.Accounts[i]))
                        {
                            Error.AddMessage("Group " + Name + " is different");
                            return false;
                        }
                    }
                }
            }

            // if not recursive, we're done here
            if (!recursive) return true;

            // last step: compare children
            if (Children == null && other.Children == null) return true;
            if (Children == null)
            {
                Error.AddMessage("Group " + Name + " has no children");
                return false;
            }
            if (other.Children == null)
            {
                Error.AddMessage("Group " + Name + " has children");
                return false;
            }
            if (Children.Count != other.Children.Count)
            {
                Error.AddMessage("Group " + Name + " has children: " + Children.Count + " other: " + other.Children.Count);
                return false;
            }

            for (int i = 0; i < Children.Count; i++)
            {
                if (!Children[i].Equals(other.Children[i], true, includeAccounts))
                {
                    Error.AddMessage("Child Group " + Name + " is different");
                    return false;
                }
            }

            // passed all tests
            return true;
        }
    }
}
