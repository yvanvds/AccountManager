using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.DisplayItems
{
    public class SSGroup
    {
        public ObservableCollection<SSGroup> Children { get; set; }
        public AccountApi.IGroup Base;
        public string Header { get; set; } = "No Groups Found";
        public string Icon { get; set; } = "QuestionMarkBox";

        public SSGroup(AccountApi.IGroup Base)
        {
            this.Base = Base;
            Children = new ObservableCollection<SSGroup>();

            Header = Base.Name;

            if (Base == null) return;
            if (Base.Children == null) return;
            if (Base.Children.Count == 0)
            {
                Icon = "Class";
            }
            else
            {
                Icon = "UserGroup";
                foreach (var group in Base.Children)
                {
                    Children.Add(new SSGroup(group));
                }
            }
        }
    }
}
