using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using AbstractAccountApi;

namespace AccountManager.Action
{
    class AddClassGroupToDirectory : IAction
    {
        public string Description => "Voeg deze klas toe aan Active Directory.";

        public bool CanBeApplied => true;

        public string Header => "Klas toevoegen aan Active Directory";

        public ObservableProperties.Prop<bool> InProgress { get; set; } = new ObservableProperties.Prop<bool>() { Value = false };

        public async Task Apply(LinkedGroup linkedGroup)
        {
            throw new NotImplementedException();
        }

        public AddClassGroupToDirectory(WisaApi.ClassGroup group)
        {
            this.group = group;
        }

        private WisaApi.ClassGroup group;
    }
}
